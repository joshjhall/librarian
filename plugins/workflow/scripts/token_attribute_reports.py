"""token_attribute_reports -- the six report functions of #788's token-attribute.

Each subcommand reads transcripts through token_attribute_engine, aggregates
into its own dict, and calls `emit`. They are mutually independent -- no report
calls another -- which is what made this a clean seam to split on (see the
engine module's header for the measurement that settled two disagreeing
detectors).

Every aggregation is keyed by MODEL as well as by its own dimension. That is not
decoration: an earlier draft computed one model for the whole scan and stamped
it on every row, silently attributing every other model's volume to the majority
one. Measured on a real corpus, that reported 35 spawns as one model when 5 were
another, with medians that genuinely differ (29,571 vs 34,369).

Runtime: Python 3.11+. Imported by the token-attribute.py CLI.
"""

from __future__ import annotations

import collections
import datetime
import json
import pathlib
import sys

from token_attribute_engine import (
    CHARS_PER_TOKEN,
    FLOOR_COMPONENTS,
    GROWTH_BUCKETS,
    RESULT_FLOOR_TOKENS,
    Window,
    _dominant_model,
    _model_of,
    _percentile,
    _text_of,
    _thinking_tokens,
    _tool_name_by_id,
    _window_start,
    classify_bash,
    emit,
    iter_turns,
    main_sessions,
    spawn_transcripts,
)


def cmd_debt(root: pathlib.Path, tz: datetime.tzinfo, window: Window) -> int:
    """Per-tool re-read debt: result size x turns remaining, per model.

    A tool result does not cost once. It is re-sent with every subsequent
    request for the rest of the session, so its real cost is its volume times
    how long it stays resident. This is the arithmetic behind "Bash carries 76%
    of all re-read debt" -- a figure no per-call size ranking produces, because
    an early medium result outweighs a late large one.

    Keyed by (model, tool): a result is attributed to the model of the turn that
    ISSUED the call, so a corpus spanning two models reports each separately
    instead of stamping the majority model on all of it.
    """
    # (model, tool) -> counters
    per_key: dict[tuple, dict[str, int]] = collections.defaultdict(
        lambda: {"results": 0, "tokens": 0, "debt": 0}
    )
    kept: list[dict] = []

    for jsonl in main_sessions(root):
        turns = [t for t in iter_turns(jsonl, tz) if window.contains(t["timestamp"])]
        if not turns:
            continue
        kept.extend(turns)
        names = _tool_name_by_id(turns)
        # The model that issued each call, so a result lands on the right one.
        issuer: dict[str, str] = {}
        for turn in turns:
            for block in turn["blocks"]:
                if block.get("type") == "tool_use" and block.get("id"):
                    issuer[block["id"]] = _model_of(turn)
        total = len(turns)
        for index, turn in enumerate(turns):
            remaining = total - index
            for block in turn["blocks"]:
                if block.get("type") != "tool_result":
                    continue
                tokens = len(_text_of(block)) // CHARS_PER_TOKEN
                if tokens < RESULT_FLOOR_TOKENS:
                    continue
                use_id = block.get("tool_use_id")
                tool = names.get(use_id, "(unknown)")
                model = issuer.get(use_id) or _model_of(turn)
                entry = per_key[(model, tool)]
                entry["results"] += 1
                entry["tokens"] += tokens
                entry["debt"] += tokens * remaining

    if not per_key:
        print(
            f"token-attribute: no tool results over {RESULT_FLOOR_TOKENS} tokens "
            f"under {root}.",
            file=sys.stderr,
        )
        return 3

    start = _window_start(kept, window)
    # Shares are WITHIN a model, not across the scan: "Bash is 76% of the debt"
    # is a claim about one model's session shape, and a cross-model denominator
    # would make each model's share depend on how much the others ran.
    totals: dict[str, int] = collections.defaultdict(int)
    for (model, _tool), entry in per_key.items():
        totals[model] += entry["debt"]

    rows = []
    for (model, tool), entry in sorted(
        per_key.items(), key=lambda kv: (kv[0][0], -kv[1]["debt"])
    ):
        denom = totals[model]
        share = round(100.0 * entry["debt"] / denom, 1) if denom else 0.0
        rows.append(
            [
                start,
                model,
                tool,
                entry["results"],
                entry["tokens"],
                entry["debt"],
                share,
            ]
        )
    emit(
        [
            "window_start",
            "model",
            "tool",
            "results",
            "result_tokens",
            "reread_debt",
            "debt_share_pct",
        ],
        rows,
        "debt (result tokens x turns remaining)",
        window,
    )
    return 0


def cmd_floor(root: pathlib.Path, tz: datetime.tzinfo, window: Window) -> int:
    """Context-floor decomposition: what every turn pays before any work.

    Reads the attachment records that carry the floor -- the system prompt and
    tool schemas, CLAUDE.md, the skill and agent listings -- and sizes each. The
    components are a FIXED vocabulary (FLOOR_COMPONENTS) rather than whatever
    the corpus happens to contain, because a floor whose categories drift
    between two runs cannot be compared, which is the question a floor
    measurement is asked.

    Attachment records carry no model of their own, so each is attributed to the
    session's dominant model -- the floor is a per-session property, and this is
    the one place a session-level majority is the honest answer rather than a
    collapse.
    """
    # (model, component) -> counters
    per_key: dict[tuple, dict[str, int]] = collections.defaultdict(
        lambda: {"count": 0, "tokens": 0}
    )
    kept: list[dict] = []

    for jsonl in main_sessions(root):
        turns = [t for t in iter_turns(jsonl, tz) if window.contains(t["timestamp"])]
        if not turns:
            continue
        kept.extend(turns)
        session_model = _dominant_model(turns)
        for turn in turns:
            for record in turn["records"]:
                if record.get("type") != "attachment":
                    continue
                attachment = record.get("attachment") or {}
                kind = attachment.get("type")
                if kind not in FLOOR_COMPONENTS:
                    continue
                entry = per_key[(session_model, kind)]
                entry["count"] += 1
                entry["tokens"] += len(json.dumps(attachment)) // CHARS_PER_TOKEN

    if not per_key:
        print(f"token-attribute: no floor attachments under {root}.", file=sys.stderr)
        return 3

    start_key = _window_start(kept, window)
    totals: dict[str, int] = collections.defaultdict(int)
    for (model, _kind), entry in per_key.items():
        totals[model] += entry["tokens"]

    rows = []
    for (model, kind), entry in sorted(
        per_key.items(), key=lambda kv: (kv[0][0], -kv[1]["tokens"])
    ):
        denom = totals[model]
        share = round(100.0 * entry["tokens"] / denom, 1) if denom else 0.0
        rows.append(
            [
                start_key,
                model,
                kind,
                FLOOR_COMPONENTS[kind],
                entry["count"],
                entry["tokens"],
                share,
            ]
        )
    emit(
        [
            "window_start",
            "model",
            "component",
            "label",
            "occurrences",
            "tokens",
            "floor_share_pct",
        ],
        rows,
        "floor (context paid before any work)",
        window,
    )
    return 0


def cmd_growth(root: pathlib.Path, tz: datetime.tzinfo, window: Window) -> int:
    """Per-decile cost growth within a session -- how the 3x was found.

    Splits each session into ten equal buckets of billed turns and reports the
    mean input context per turn in each. The headline is the last decile over
    the first: accumulated context means identical work costs multiples more
    late in a session than early, which is what motivates a size-triggered
    handoff (#784).

    Deciles are per-session positions, so a turn's bucket comes from its index
    within ITS OWN session -- pooling every session into one ordering would let
    a long session's tail define the last decile for all of them.
    """
    # (model, decile) -> counters
    per_key: dict[tuple, dict[str, int]] = collections.defaultdict(
        lambda: {"turns": 0, "input": 0, "output": 0, "thinking": 0}
    )
    kept: list[dict] = []

    for jsonl in main_sessions(root):
        turns = [
            t
            for t in iter_turns(jsonl, tz)
            if t["usage"] and window.contains(t["timestamp"])
        ]
        if not turns:
            continue
        kept.extend(turns)
        total = len(turns)
        for index, turn in enumerate(turns):
            slot = min(index * GROWTH_BUCKETS // total, GROWTH_BUCKETS - 1)
            usage = turn["usage"]
            context = (
                usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
            )
            entry = per_key[(_model_of(turn), slot)]
            entry["turns"] += 1
            entry["input"] += context
            entry["output"] += usage.get("output_tokens", 0)
            entry["thinking"] += _thinking_tokens(usage)

    if not kept:
        print(f"token-attribute: no billed turns under {root}.", file=sys.stderr)
        return 3

    start_key = _window_start(kept, window)
    rows = []
    for model in sorted({m for m, _slot in per_key}):
        first = per_key.get((model, 0))
        base = (first["input"] / first["turns"]) if first and first["turns"] else 0.0
        for slot in range(GROWTH_BUCKETS):
            entry = per_key.get((model, slot))
            # A decile with NO turns is not a zero-cost decile, and emitting 0
            # for both mean and ratio makes the two indistinguishable to a
            # reader scanning the headline column. The `-` sentinel says "no
            # data" in the same spelling window_start already uses.
            if not entry or not entry["turns"]:
                rows.append([start_key, model, slot + 1, 0, "-", 0, 0, "-"])
                continue
            mean = entry["input"] / entry["turns"]
            ratio = round(mean / base, 2) if base else "-"
            rows.append(
                [
                    start_key,
                    model,
                    slot + 1,
                    entry["turns"],
                    int(mean),
                    entry["output"],
                    entry["thinking"],
                    ratio,
                ]
            )
    emit(
        [
            "window_start",
            "model",
            "decile",
            "turns",
            "mean_input_tokens",
            "output_tokens",
            "thinking_tokens",
            "growth_vs_first",
        ],
        rows,
        "growth (per-decile cost within a session)",
        window,
    )
    return 0


def cmd_prefix(root: pathlib.Path, tz: datetime.tzinfo, window: Window) -> int:
    """Subagent prefix distribution across spawns, per model.

    A spawn's prefix is the input context of its first billed turn -- the system
    prompt, tool schemas and dispatch prompt sent before it does any work. The
    distribution matters more than the mean: the break-even that decides whether
    to delegate is a median, and a long tail is what makes an average mislead.

    Grouped by model because a spawn's prefix is dominated by the system prompt
    and tool schemas, which differ per model -- pooling two models produces a
    median that describes neither.
    """
    per_model: dict[str, list[int]] = collections.defaultdict(list)
    thinking: dict[str, int] = collections.defaultdict(int)
    kept: list[dict] = []

    for jsonl in spawn_transcripts(root):
        for turn in iter_turns(jsonl, tz):
            usage = turn["usage"]
            if not usage:
                continue
            context = (
                usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
            )
            if context <= 0:
                continue
            # The window test happens HERE, on the first billed turn, because a
            # spawn belongs to the window it was dispatched in.
            if not window.contains(turn["timestamp"]):
                break
            model = _model_of(turn)
            kept.append(turn)
            per_model[model].append(context)
            thinking[model] += _thinking_tokens(usage)
            break

    if not per_model:
        print(f"token-attribute: no subagent spawns under {root}.", file=sys.stderr)
        return 3

    start_key = _window_start(kept, window)
    rows = []
    for model in sorted(per_model):
        prefixes = sorted(per_model[model])
        rows.append(
            [
                start_key,
                model,
                len(prefixes),
                _percentile(prefixes, 0.5),
                _percentile(prefixes, 0.9),
                prefixes[0],
                prefixes[-1],
                sum(prefixes),
                thinking[model],
            ]
        )
    emit(
        [
            "window_start",
            "model",
            "spawns",
            "median_prefix",
            "p90_prefix",
            "min_prefix",
            "max_prefix",
            "total_prefix",
            "thinking_tokens",
        ],
        rows,
        "prefix (subagent spawn prefix distribution)",
        window,
    )
    return 0


def cmd_bash_class(root: pathlib.Path, tz: datetime.tzinfo, window: Window) -> int:
    """Bash command read-vs-mutate classification -- the 49%/67% split.

    Two shares, and they are different numbers: the share of CALLS that are
    read-only investigation, and the share of RESULT TOKENS those calls produce.
    The second is the larger one and the one that matters, because a read
    produces far more output than a mutation.
    """
    # (model, class) -> counters
    per_key: dict[tuple, dict[str, int]] = collections.defaultdict(
        lambda: {"calls": 0, "tokens": 0}
    )
    kept: list[dict] = []

    for jsonl in main_sessions(root):
        turns = [t for t in iter_turns(jsonl, tz) if window.contains(t["timestamp"])]
        if not turns:
            continue
        kept.extend(turns)
        # Result sizes are attributed back to the call they answer, which is in
        # an earlier turn -- so index the results first, then walk the calls.
        results: dict[str, int] = {}
        for turn in turns:
            for block in turn["blocks"]:
                if block.get("type") == "tool_result" and block.get("tool_use_id"):
                    results[block["tool_use_id"]] = len(_text_of(block))
        for turn in turns:
            model = _model_of(turn)
            for block in turn["blocks"]:
                if block.get("type") != "tool_use" or block.get("name") != "Bash":
                    continue
                command = (block.get("input") or {}).get("command", "")
                verdict = classify_bash(command if isinstance(command, str) else "")
                entry = per_key[(model, verdict)]
                entry["calls"] += 1
                entry["tokens"] += results.get(block.get("id"), 0) // CHARS_PER_TOKEN

    if not per_key:
        print(f"token-attribute: no Bash calls under {root}.", file=sys.stderr)
        return 3

    start_key = _window_start(kept, window)
    call_totals: dict[str, int] = collections.defaultdict(int)
    token_totals: dict[str, int] = collections.defaultdict(int)
    for (model, _verdict), entry in per_key.items():
        call_totals[model] += entry["calls"]
        token_totals[model] += entry["tokens"]

    rows = []
    for model in sorted({m for m, _v in per_key}):
        for verdict in ("read", "mutate", "other"):
            entry = per_key.get((model, verdict), {"calls": 0, "tokens": 0})
            calls_denom = call_totals[model]
            tokens_denom = token_totals[model]
            rows.append(
                [
                    start_key,
                    model,
                    verdict,
                    entry["calls"],
                    round(100.0 * entry["calls"] / calls_denom, 1)
                    if calls_denom
                    else 0.0,
                    entry["tokens"],
                    round(100.0 * entry["tokens"] / tokens_denom, 1)
                    if tokens_denom
                    else 0.0,
                ]
            )
    emit(
        [
            "window_start",
            "model",
            "class",
            "calls",
            "call_share_pct",
            "result_tokens",
            "token_share_pct",
        ],
        rows,
        "bash-class (read vs mutate)",
        window,
    )
    return 0


def cmd_attachments(root: pathlib.Path, tz: datetime.tzinfo, window: Window) -> int:
    """Attachment-type volume -- how the no-op `hook_success` finding surfaced.

    Enumerates whatever attachment types the corpus contains, with count and
    total size. Unlike `floor` this vocabulary is OPEN on purpose: the finding
    it reproduces was a type nobody expected to be there at all, and a fixed
    list would have filtered exactly that discovery out.
    """
    # (model, attachment type) -> counters
    per_key: dict[tuple, dict[str, int]] = collections.defaultdict(
        lambda: {"count": 0, "tokens": 0}
    )
    kept: list[dict] = []

    for jsonl in main_sessions(root) + spawn_transcripts(root):
        turns = [t for t in iter_turns(jsonl, tz) if window.contains(t["timestamp"])]
        if not turns:
            continue
        kept.extend(turns)
        session_model = _dominant_model(turns)
        for turn in turns:
            for record in turn["records"]:
                if record.get("type") != "attachment":
                    continue
                attachment = record.get("attachment") or {}
                kind = attachment.get("type") or "(untyped)"
                entry = per_key[(session_model, kind)]
                entry["count"] += 1
                entry["tokens"] += len(json.dumps(attachment)) // CHARS_PER_TOKEN

    if not per_key:
        print(f"token-attribute: no attachments under {root}.", file=sys.stderr)
        return 3

    start_key = _window_start(kept, window)
    totals: dict[str, int] = collections.defaultdict(int)
    for (model, _kind), entry in per_key.items():
        totals[model] += entry["tokens"]

    rows = []
    for (model, kind), entry in sorted(
        per_key.items(), key=lambda kv: (kv[0][0], -kv[1]["tokens"])
    ):
        mean = entry["tokens"] // entry["count"] if entry["count"] else 0
        denom = totals[model]
        share = round(100.0 * entry["tokens"] / denom, 1) if denom else 0.0
        rows.append(
            [start_key, model, kind, entry["count"], entry["tokens"], mean, share]
        )
    emit(
        [
            "window_start",
            "model",
            "attachment_type",
            "occurrences",
            "tokens",
            "mean_tokens",
            "share_pct",
        ],
        rows,
        "attachments (per-type volume)",
        window,
    )
    return 0
