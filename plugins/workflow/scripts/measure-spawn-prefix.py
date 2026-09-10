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
  timing     WHY a miss happens: miss rate against spawn order within a fan-out
             barrier and against the gap since the previous barrier (#870)

Exit codes: 0 = success; 2 = usage error; 3 = no transcripts found.

Runtime: Python 3.11+. Unlike the patterns.sh pre-scan family this tool has NO
bash fallback — it walks newline-delimited JSON transcripts, which bash 3.2
cannot do correctly. The sibling shim fails loud rather than degrade. See
CLAUDE.md § Key conventions (runtime policy).
"""

from __future__ import annotations

import argparse
import collections
import datetime
import json
import math
import pathlib
import statistics
import sys

# Anthropic prompt-cache multipliers, relative to base input price. A cache read
# bills at a tenth; writing an entry costs a 25% premium over base.
CACHE_READ_MULTIPLIER = 0.1
CACHE_WRITE_MULTIPLIER = 1.25

# `timing` groups spawns into BARRIERS: consecutive spawns of one session
# dispatched as a single fan-out. There is no barrier id in the transcript, so
# the grouping is inferred from dispatch latency — a fan-out's siblings start
# within a few seconds of each other, while the next cycle is separated by the
# reviewers' own runtime plus (on a ship) a CI wait.
#
# 20s is comfortably above the widest observed intra-barrier spread (the
# leader->2nd-spawn delta tops out near 19s on a 7-way fan-out) and far below
# the smallest inter-barrier gap. The verdict is not sensitive to the exact
# value: the leader/follower split it produces is a ~5x rate difference, which
# no plausible threshold in that range erases.
BARRIER_GAP_SECONDS = 20.0

# The Anthropic prompt cache's documented TTL. `timing` buckets the gap before a
# barrier around it to separate TTL expiry from per-barrier allocation.
CACHE_TTL_SECONDS = 300.0

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


def _parse_ts(raw: object) -> datetime.datetime | None:
    """Parse a transcript ISO-8601 timestamp, tolerating a trailing `Z`.

    Returns None for anything unparseable rather than raising: a spawn with no
    usable timestamp simply cannot be placed in a barrier, and dropping it is
    the same degradation an unreadable sidecar gets. `fromisoformat` accepts `Z`
    only from 3.11 — which this module already requires — but the explicit
    replace keeps the parse working if that floor is ever lowered.
    """
    if not isinstance(raw, str):
        return None
    try:
        return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _agent_type(jsonl: pathlib.Path) -> str:
    """Read the spawn's declared agentType from its sidecar meta file."""
    meta = jsonl.with_suffix(".meta.json")
    if not meta.exists():
        return "(unknown)"
    try:
        data = json.loads(meta.read_text())
    except (OSError, ValueError):
        return "(unknown)"
    # Guard the SHAPE as well as the parse. `[1,2,3]`, `"x"` and `42` are all
    # valid JSON, so they sail past the except above and then raise
    # AttributeError on .get() — uncaught, aborting the whole run over one
    # malformed sidecar among possibly dozens of good transcripts. Degrading to
    # the same fallback an unparseable sidecar gets is the advertised contract.
    if not isinstance(data, dict):
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
        input_total = 0
        prompt_chars = 0
        seen_first = False
        session = None
        started = None

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
            input_total += context
            if not seen_first:
                seen_first = True
                prefix, cached, written = context, read, create
                # Identity and wall-clock of the FIRST billed turn — the two
                # fields `timing` clusters on. Taken here rather than from the
                # transcript's first line because that line may be an unbilled
                # record, and a spawn's position in a barrier is defined by when
                # it was billed, not when its file was opened.
                session = record.get("sessionId")
                started = _parse_ts(record.get("timestamp"))

        if seen_first:
            yield {
                "file": str(jsonl.relative_to(root)),
                "agent_type": _agent_type(jsonl),
                "prefix": prefix,
                "cached": cached,
                "written": written,
                "turns": turns,
                "cache_read": cache_read_total,
                "input_total": input_total,
                "prompt_tokens_est": round(prompt_chars / 4),
                "session": session,
                "started": started,
            }


def _percentile(values: list[int], fraction: float) -> int:
    """Nearest-rank percentile: the smallest value at or above `fraction` of the data.

    `int(n * fraction)` is one rank too high and collapses to the MAXIMUM
    whenever `n * fraction` lands on an integer — at n=10 or n=100 the reported
    p90 was simply `max`, hiding exactly the gap between the 90th percentile and
    the outlier that a p90 is quoted to show. The n=4 fixture could not see it:
    there p90 and max legitimately coincide either way.
    """
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[min(len(ordered) - 1, index)]


def cmd_summary(spawns: list[dict]) -> None:
    prefixes = [s["prefix"] for s in spawns]
    turns = sum(s["turns"] for s in spawns)
    cache_read = sum(s["cache_read"] for s in spawns)
    input_total = sum(s["input_total"] for s in spawns)
    prefix_x_turns = sum(s["prefix"] * s["turns"] for s in spawns)

    print(f"spawns                 {len(spawns):,}")
    print(f"prefix min             {min(prefixes):,}")
    print(f"prefix median          {int(statistics.median(prefixes)):,}")
    print(f"prefix p90             {_percentile(prefixes, 0.9):,}")
    print(f"prefix max             {max(prefixes):,}")
    print(f"total subagent turns   {turns:,}")
    print(f"subagent cache_read    {cache_read:,}")
    print(f"prefix x turns         {prefix_x_turns:,}")
    # Share of ALL input the prefix accounts for.
    #
    # Two things were wrong here and both only showed up under a fixture:
    #
    # 1. The denominator was `cache_read` alone. A cache MISS puts those same
    #    tokens in cache_creation, so on a miss-heavy corpus they left the
    #    denominator while staying in the numerator — 427.8%. It must be total
    #    input across every turn (input_tokens + cache_read + cache_creation).
    # 2. `prefix x turns` is an UPPER BOUND, not a measurement. It assumes the
    #    full prefix is re-sent on every turn, which holds for a real transcript
    #    but not for a short or truncated one whose later turns carry less than
    #    the first. So the ratio can legitimately exceed 100%, and printing a
    #    bare ">100% share" would be nonsense rather than a finding.
    #
    # Both bugs read as a plausible ~65% on the real hit-dominated corpus, which
    # is exactly why neither surfaced until the synthetic fixture ran them.
    if input_total:
        share = 100 * prefix_x_turns / input_total
        if share > 100:
            print(
                f"prefix share of input  >100% (bound {share:.1f}%) — "
                f"prefix x turns exceeds measured input; short transcripts"
            )
        else:
            print(f"prefix share of input  {share:.1f}% (upper bound)")
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

    print(f"\nmean cache_creation on HIT   {hit_written:,.0f}")
    print(f"mean cache_creation on MISS  {miss_written:,.0f}")

    # The shared block is INFERRED from a difference of two group means, so it is
    # only meaningful when the miss group wrote more. A skewed sample can invert
    # that — a few hit-group spawns carrying unusually large per-spawn payloads
    # (a big diff, a fat pre-scan handoff) is enough — and then `shared` goes
    # negative and every figure derived from it becomes a physically impossible
    # negative token count. Say the sample cannot support the estimate instead of
    # printing one, on the same principle as the no-misses early return above.
    if shared <= 0:
        print(
            "implied shared block         n/a — the hit group wrote MORE than the\n"
            "                             miss group, so this sample cannot size\n"
            "                             the shared block. Collect more spawns."
        )
        return

    penalty = (CACHE_WRITE_MULTIPLIER - CACHE_READ_MULTIPLIER) * shared
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


def build_barriers(spawns: list[dict]) -> list[list[dict]]:
    """Group spawns into fan-out barriers, annotating rank and inter-barrier gap.

    A barrier is a run of consecutive same-session spawns each starting within
    BARRIER_GAP_SECONDS of its predecessor. Spawns missing a session or a
    timestamp are dropped — they cannot be ordered, and guessing a position
    would fabricate exactly the signal this report exists to measure.

    Each spawn gains `rank` (0 = the barrier's leader) and each barrier's leader
    gains `gap_before`: seconds since the previous barrier's last member
    **started** — i.e. since that spawn's first billed turn, which is when it
    touched the cache. It is deliberately NOT the previous barrier's completion
    time: a transcript records only each spawn's first billed turn, so no end
    timestamp exists to use, and the cache-touch instant is the quantity a TTL
    question actually wants. Do not read this as including the previous
    barrier's runtime.

    `gap_before` is None when the barrier is the session's first — a cold start,
    which has no prior entry to reuse and so belongs in its own category rather
    than in the largest gap bucket.
    """
    ordered = [s for s in spawns if s.get("session") and s.get("started")]
    ordered.sort(key=lambda s: (s["session"], s["started"]))

    barriers: list[list[dict]] = []
    for spawn in ordered:
        current = barriers[-1] if barriers else None
        if (
            current
            and current[-1]["session"] == spawn["session"]
            and (spawn["started"] - current[-1]["started"]).total_seconds()
            <= BARRIER_GAP_SECONDS
        ):
            current.append(spawn)
        else:
            barriers.append([spawn])

    previous_end: dict[str, datetime.datetime] = {}
    for barrier in barriers:
        session = barrier[0]["session"]
        prior = previous_end.get(session)
        barrier[0]["gap_before"] = (
            (barrier[0]["started"] - prior).total_seconds() if prior else None
        )
        previous_end[session] = barrier[-1]["started"]
        for rank, spawn in enumerate(barrier):
            spawn["rank"] = rank
    return barriers


def _rate_row(label: str, misses: int, total: int) -> str:
    pct = f"{100 * misses / total:.0f}%" if total else "n/a"
    return f"  {label:<26}{misses:>4}/{total:<5}{pct:>6}"


def cmd_timing(spawns: list[dict]) -> None:
    """Correlate cache misses against spawn order and cycle boundaries (#870).

    #870 named three hypotheses — a 5-minute TTL expiring between review cycles,
    barrier scheduling racing to populate the cache, and cold-start floor — and
    asked for timing evidence BEFORE any fix, because the first two make
    distinguishable predictions. This report is that evidence. The measured
    answer is that the first two are BOTH real: a barrier's leader carries the
    great majority of misses (the barrier effect) and its miss probability then
    climbs with the gap since the previous barrier (the TTL effect).
    """
    barriers = build_barriers(spawns)
    if not barriers:
        print(
            "no spawn carries both a sessionId and a timestamp — "
            "cannot reconstruct barriers from this corpus"
        )
        return

    placed = sum(len(b) for b in barriers)
    print(f"spawns placed in barriers   {placed:,} of {len(spawns):,}")
    print(f"barriers                    {len(barriers):,}")
    print(f"barrier gap threshold       {BARRIER_GAP_SECONDS:.0f}s\n")

    # --- Spawn order: does position within the fan-out predict a miss? --------
    by_rank: dict[int, list[int]] = collections.defaultdict(lambda: [0, 0])
    for barrier in barriers:
        for spawn in barrier:
            # Rank 5+ is pooled: past the fifth sibling the per-rank samples are
            # too thin to read, and the question is leader-vs-follower anyway.
            by_rank[min(spawn["rank"], 5)][not spawn["cached"]] += 1

    print("rank within barrier (0 = the spawn that opens the fan-out):")
    print(f"  {'rank':<26}{'miss':>4}/{'n':<5}{'rate':>6}")
    for rank in sorted(by_rank):
        hits, misses = by_rank[rank]
        label = "5+" if rank == 5 else str(rank)
        print(_rate_row(label, misses, hits + misses))

    # --- Cycle boundaries: does the gap before a barrier predict a miss? -----
    buckets = [
        ("0-30s", 0.0, 30.0),
        ("30-60s", 30.0, 60.0),
        ("60-120s", 60.0, 120.0),
        ("120-300s", 120.0, CACHE_TTL_SECONDS),
        ("300-600s", CACHE_TTL_SECONDS, 600.0),
        ("600s+", 600.0, float("inf")),
    ]
    by_gap: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0])
    cold = [0, 0]
    for barrier in barriers:
        leader = barrier[0]
        gap = leader["gap_before"]
        if gap is None:
            cold[not leader["cached"]] += 1
            continue
        for label, low, high in buckets:
            if low <= gap < high:
                by_gap[label][not leader["cached"]] += 1
                break

    print("\nleader miss rate by gap since the session's previous barrier")
    print(f"  (TTL is {CACHE_TTL_SECONDS:.0f}s — a pure-TTL cause would step there and")
    print("   be flat below it):")
    print(f"  {'gap':<26}{'miss':>4}/{'n':<5}{'rate':>6}")
    for label, _low, _high in buckets:
        hits, misses = by_gap[label]
        if hits + misses:
            print(_rate_row(label, misses, hits + misses))
    if sum(cold):
        print(_rate_row("cold (session's first)", cold[1], sum(cold)))

    # --- Attribution: where does the penalty actually accrue? ----------------
    #
    # Cost per miss is derived exactly as cmd_cache derives it — the shared block
    # inferred from the difference of the two group means, priced at the spread
    # between the write and read multipliers. Re-deriving the cost model here
    # would let the two reports disagree about the same corpus.
    hits = [s for s in spawns if s["cached"]]
    misses = [s for s in spawns if not s["cached"]]
    shared = 0.0
    if hits and misses:
        shared = statistics.mean(s["written"] for s in misses) - statistics.mean(
            s["written"] for s in hits
        )
    penalty = max(0.0, (CACHE_WRITE_MULTIPLIER - CACHE_READ_MULTIPLIER) * shared)

    categories: collections.Counter[str] = collections.Counter()
    for barrier in barriers:
        for spawn in barrier:
            if spawn["cached"]:
                continue
            if spawn["rank"] > 0:
                categories["follower (within a barrier)"] += 1
            elif spawn["gap_before"] is None:
                categories["leader, session cold start"] += 1
            # `>=`, not `>`, to match the bucket table above, whose half-open
            # `low <= gap < high` intervals put a gap of exactly
            # CACHE_TTL_SECONDS in the "300-600s" row. A strict `>` here read
            # that same spawn as in-TTL, so one report disagreed with itself at
            # the boundary — and this tool exists to be hand-checkable.
            elif spawn["gap_before"] >= CACHE_TTL_SECONDS:
                categories["leader, gap >= TTL"] += 1
            else:
                categories["leader, gap < TTL"] += 1

    total_misses = sum(categories.values())
    print("\nmiss attribution:")
    if not total_misses:
        print("  no misses in this corpus")
        return
    for name, count in categories.most_common():
        share = 100 * count / total_misses
        cost = f"{count * penalty:,.0f} tok-equiv" if penalty else "n/a"
        print(f"  {name:<30}{count:>4}  ({share:>3.0f}%)  {cost:>22}")
    if penalty:
        print(f"\n  total penalty              {total_misses * penalty:,.0f} tok-equiv")
    else:
        # Same refusal cmd_cache makes: without both groups (or with an inverted
        # sample) the shared block cannot be sized, and a fabricated cost is
        # worse than an absent one.
        print("\n  (cost per miss unavailable — this sample cannot size the")
        print("   shared block; see the `cache` subcommand)")


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
        choices=("summary", "split", "cache", "timing"),
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

    {
        "summary": cmd_summary,
        "split": cmd_split,
        "cache": cmd_cache,
        "timing": cmd_timing,
    }[args.subcommand](spawns)
    return 0


if __name__ == "__main__":
    sys.exit(main())
