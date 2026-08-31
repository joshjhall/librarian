#!/usr/bin/env python3
"""measure-spawn-prefix — measure what a subagent spawn actually costs.

Reads local Claude Code subagent transcripts and reports the per-spawn *prefix*:
the first-turn input context (system prompt + tool schemas + dispatch prompt)
that is sent before the agent does any work.

Filed for issue #787, whose premise — that the prefix is driven by broad `tools:`
declarations — this instrument falsified. See
docs/verification/subagent-prefix-e2e-787.md.

The headline number everyone quotes ("24.5k median prefix") conflates two things
that bill an order of magnitude apart:

  cache_read      the shared system-prompt + tool-schema block. Byte-identical
                  across spawns, so it is normally a cache HIT and bills at ~10%
                  of list price.
  cache_creation  bytes unique to this spawn (the dispatch prompt, the diff, a
                  pre-scan handoff) — plus the shared block whenever the cache
                  MISSED. Billed at ~125% on write.

Ranking cuts by raw prefix size therefore mis-ranks them: a 12k shared block on a
cache hit costs ~1.2k tok-equiv, and the same 12k on a miss costs ~15k. This tool
reports both columns so a saving is attributed to the component that carries it.

Subcommands:
  summary    per-spawn prefix stats + prefix x turns attribution (default)
  split      per-spawn cached-vs-written split and billing-weighted cost
  cache      cache HIT/MISS rate and the measured penalty of a miss

Exit codes: 0 = success; 2 = usage error; 3 = no transcripts found.

Runtime: Python 3.11+. Unlike the patterns.sh pre-scan family this tool has NO
bash fallback — it walks newline-delimited JSON transcripts, which bash 3.2
cannot do correctly. The sibling shim fails loud rather than degrade. See
CLAUDE.md § Key conventions (runtime policy).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import sys

# Anthropic prompt-cache multipliers, relative to base input price. A cache read
# bills at a tenth; writing an entry costs a 25% premium over base.
CACHE_READ_MULTIPLIER = 0.1
CACHE_WRITE_MULTIPLIER = 1.25

MIN_PYTHON = (3, 11)


def _require_python() -> None:
    """Fail loud on an unsupported interpreter rather than emit wrong numbers."""
    if sys.version_info < MIN_PYTHON:
        want = ".".join(str(p) for p in MIN_PYTHON)
        have = ".".join(str(p) for p in sys.version_info[:3])
        sys.exit(
            f"measure-spawn-prefix: needs Python >= {want}, got {have}.\n"
            f"Install a newer python3 or run via the sibling "
            f"measure-spawn-prefix.sh shim."
        )


def transcript_root() -> pathlib.Path:
    return pathlib.Path.home() / ".claude" / "projects"


def _usage(record: dict) -> dict:
    """Pull the usage block, which sits under `message` on assistant records."""
    return (record.get("message") or {}).get("usage") or record.get("usage") or {}


def _agent_type(jsonl: pathlib.Path) -> str:
    """Read the spawn's declared agentType from its sidecar meta file."""
    meta = jsonl.with_suffix(".meta.json")
    if not meta.exists():
        return "(unknown)"
    try:
        data = json.loads(meta.read_text())
    except (OSError, ValueError):
        return "(unknown)"
    return data.get("agentType") or data.get("subagent_type") or "(unknown)"


def iter_spawns(root: pathlib.Path):
    """Yield one record per subagent transcript found under `root`.

    A spawn's prefix is the input context of its FIRST billed turn — the first
    record carrying non-zero usage. Later turns re-send that prefix plus the
    conversation so far, which is why `prefix x turns` (not the one-shot spawn
    cost) is the figure that dominates fan-out input.
    """
    for jsonl in sorted(root.rglob("subagents/**/*.jsonl")):
        if jsonl.name == "journal.jsonl":
            continue
        try:
            lines = jsonl.read_text().splitlines()
        except OSError as exc:
            print(f"warning: unreadable {jsonl}: {exc}", file=sys.stderr)
            continue

        prefix = cached = written = turns = cache_read_total = 0
        prompt_chars = 0
        seen_first = False

        for line in lines:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue

            message = record.get("message") or {}
            if not seen_first and message.get("role") == "user" and not prompt_chars:
                content = message.get("content")
                prompt_chars = (
                    len(content)
                    if isinstance(content, str)
                    else len(json.dumps(content))
                )

            usage = _usage(record)
            read = usage.get("cache_read_input_tokens", 0)
            create = usage.get("cache_creation_input_tokens", 0)
            context = usage.get("input_tokens", 0) + read + create
            if context <= 0:
                continue

            turns += 1
            cache_read_total += read
            if not seen_first:
                seen_first = True
                prefix, cached, written = context, read, create

        if seen_first:
            yield {
                "file": str(jsonl.relative_to(root)),
                "agent_type": _agent_type(jsonl),
                "prefix": prefix,
                "cached": cached,
                "written": written,
                "turns": turns,
                "cache_read": cache_read_total,
                "prompt_tokens_est": round(prompt_chars / 4),
            }


def _percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def cmd_summary(spawns: list[dict]) -> None:
    prefixes = [s["prefix"] for s in spawns]
    turns = sum(s["turns"] for s in spawns)
    cache_read = sum(s["cache_read"] for s in spawns)
    prefix_x_turns = sum(s["prefix"] * s["turns"] for s in spawns)

    print(f"spawns                 {len(spawns):,}")
    print(f"prefix min             {min(prefixes):,}")
    print(f"prefix median          {int(statistics.median(prefixes)):,}")
    print(f"prefix p90             {_percentile(prefixes, 0.9):,}")
    print(f"prefix max             {max(prefixes):,}")
    print(f"total subagent turns   {turns:,}")
    print(f"subagent cache_read    {cache_read:,}")
    print(f"prefix x turns         {prefix_x_turns:,}")
    if cache_read:
        print(f"prefix share of input  {100 * prefix_x_turns / cache_read:.1f}%")
    print(f"one-shot spawn cost    {sum(prefixes):,}")

    by_type: dict[str, list[int]] = {}
    for spawn in spawns:
        by_type.setdefault(spawn["agent_type"], []).append(spawn["prefix"])

    print("\nper-agent-type prefix (median):")
    for name, values in sorted(
        by_type.items(), key=lambda kv: -statistics.median(kv[1])
    ):
        print(f"  {name:<40} n={len(values):<4} {int(statistics.median(values)):,}")


def cmd_split(spawns: list[dict]) -> None:
    print(f"{'agent_type':<32}{'cached':>10}{'written':>10}{'prompt~':>10}")
    for spawn in spawns:
        print(
            f"{spawn['agent_type']:<32}{spawn['cached']:>10,}"
            f"{spawn['written']:>10,}{spawn['prompt_tokens_est']:>10,}"
        )

    weighted = [
        CACHE_READ_MULTIPLIER * s["cached"] + CACHE_WRITE_MULTIPLIER * s["written"]
        for s in spawns
    ]
    total = sum(weighted)
    cached_cost = sum(CACHE_READ_MULTIPLIER * s["cached"] for s in spawns)
    written_cost = sum(CACHE_WRITE_MULTIPLIER * s["written"] for s in spawns)

    cached_median = int(statistics.median([s["cached"] for s in spawns]))
    written_median = int(statistics.median([s["written"] for s in spawns]))

    print(f"\nspawns                     {len(spawns):,}")
    print(f"cached  median             {cached_median:,}")
    print(f"written median             {written_median:,}")
    print(
        f"\nBilling-weighted first turn "
        f"(read x{CACHE_READ_MULTIPLIER}, write x{CACHE_WRITE_MULTIPLIER}):"
    )
    print(f"  median weighted tokens   {int(statistics.median(weighted)):,}")
    if total:
        print(f"  cached share             {100 * cached_cost / total:.1f}%")
        print(f"  written share            {100 * written_cost / total:.1f}%")


def cmd_cache(spawns: list[dict]) -> None:
    hits = [s for s in spawns if s["cached"]]
    misses = [s for s in spawns if not s["cached"]]
    total = len(spawns)

    print(f"spawns                {total:,}")
    print(f"cache HIT             {len(hits):,}  ({100 * len(hits) / total:.0f}%)")
    print(f"cache MISS            {len(misses):,}  ({100 * len(misses) / total:.0f}%)")

    if not hits or not misses:
        print("\n(need both hits and misses present to size the miss penalty)")
        return

    # On a miss the shared block is WRITTEN instead of read, so it lands in
    # cache_creation. The difference between mean written-on-miss and
    # written-on-hit is that shared block.
    hit_written = statistics.mean(s["written"] for s in hits)
    miss_written = statistics.mean(s["written"] for s in misses)
    shared = miss_written - hit_written
    penalty = (CACHE_WRITE_MULTIPLIER - CACHE_READ_MULTIPLIER) * shared

    print(f"\nmean cache_creation on HIT   {hit_written:,.0f}")
    print(f"mean cache_creation on MISS  {miss_written:,.0f}")
    print(f"implied shared block         {shared:,.0f} tokens")
    hit_cost = CACHE_READ_MULTIPLIER * shared
    miss_cost = CACHE_WRITE_MULTIPLIER * shared
    print(f"\ncost of shared block, HIT    {hit_cost:,.0f} tok-equiv")
    print(f"cost of shared block, MISS   {miss_cost:,.0f} tok-equiv")
    print(
        f"miss penalty per spawn       {penalty:,.0f} tok-equiv "
        f"({CACHE_WRITE_MULTIPLIER / CACHE_READ_MULTIPLIER:.0f}x)"
    )
    print(f"total penalty paid           {len(misses) * penalty:,.0f} tok-equiv")


def main(argv: list[str] | None = None) -> int:
    _require_python()

    parser = argparse.ArgumentParser(
        prog="measure-spawn-prefix",
        description="Measure subagent spawn prefix cost from local transcripts.",
    )
    parser.add_argument(
        "subcommand",
        nargs="?",
        default="summary",
        choices=("summary", "split", "cache"),
        help="which report to emit (default: summary)",
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
        print(f"measure-spawn-prefix: no transcript root at {root}", file=sys.stderr)
        return 3

    spawns = list(iter_spawns(root))
    if not spawns:
        print(
            f"measure-spawn-prefix: no subagent transcripts under {root}.\n"
            f"Spawn at least one subagent (e.g. a ship-issue review cycle) first.",
            file=sys.stderr,
        )
        return 3

    {"summary": cmd_summary, "split": cmd_split, "cache": cmd_cache}[args.subcommand](
        spawns
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
