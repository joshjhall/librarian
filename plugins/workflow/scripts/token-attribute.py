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
import collections
import datetime
import json
import pathlib
import sys

MIN_PYTHON = (3, 11)

# Rough chars-per-token divisor for sizing tool results and attachments.
# Deliberately crude, and the same figure the sibling delegation-adoption.py
# uses: these numbers rank things whose ratios differ by multiples, so a real
# tokenizer would not move a row. Keeping the two tools on one divisor is what
# lets their outputs be compared at all.
CHARS_PER_TOKEN = 4

# Floor below which a tool result is not worth attributing debt to -- a status
# line, a short git output. Without it the debt table is dominated by hundreds of
# trivial results whose products are noise. Same value and same reasoning as
# delegation-adoption.py's RESULT_FLOOR_TOKENS.
RESULT_FLOOR_TOKENS = 2_000

# How many buckets `growth` splits a session into. Deciles because that is what
# the 2026-08-23 finding used ("per-decile cost growth ... how the 3x was
# found"); reproducing that figure requires the same bucketing.
GROWTH_BUCKETS = 10

# Bash commands classified as READ-ONLY investigation. The 49%/67% split finding
# (#785, now cited in delegating-investigation/SKILL.md) rests on this list, so
# it is stated once here rather than re-derived per caller.
#
# Classification is by the FIRST word of each pipeline segment, so
# `git log | head` is read and `sed -i ...` is not. A command whose head word is
# unknown is counted `other`, never silently folded into either side -- an
# unknown must not be able to move the ratio the finding quotes.
READ_COMMANDS = frozenset(
    """awk basename cat cd cut date df diff dirname du echo file find grep
    head jq less ls md5sum nl od printf ps pwd readlink realpath rg sed seq sort
    stat tail test tr type uniq wc which whoami xxd yes""".split()
)

# Commands that change something -- the other arm of the same split.
#
# `tee` sits here rather than with the readers it usually accompanies: it is
# almost always the tail of a read pipeline, but what it DOES is write a file.
# Classifying it as a read is what makes `cat x | tee out.txt` report as pure
# investigation, which is the direction that overstates the read share the
# finding quotes -- so the pipeline rule below (any segment mutates => mutate)
# only bites if `tee` is on this side.
#
# `sudo` and `env` appear in NEITHER set on purpose: SHELL_PREFIXES strips them
# before classification, so what gets classified is the command they wrap.
# Listing them here or above would be dead configuration that reads as live.
MUTATE_COMMANDS = frozenset(
    """chmod chown cp curl dd gh git install ln mkdir mv npm pip python python3
    rm rmdir ruff rsync ssh tar tee touch unzip uv uvx wget zip""".split()
)

# Shell prefixes that wrap a real command. `command grep ...` is a grep call,
# not a call to something named `command`; this repo's own scripts use that
# spelling throughout, so failing to strip it would dump a large share of the
# corpus into `other` and quietly deflate the read share.
SHELL_PREFIXES = frozenset("command builtin exec time nohup sudo env".split())

# Commands that read OR mutate depending on their subcommand, resolved by
# looking at the second word. Without this `git log` and `git push` land in the
# same bucket, and git is by far the most common head word in this corpus -- so
# collapsing it would dominate the very ratio being measured.
SUBCOMMAND_READ = {
    "git": frozenset(
        "blame branch cat-file diff log ls-files rev-parse show status".split()
    ),
    "gh": frozenset("api browse issue pr release repo run search view".split()),
    "npm": frozenset("list ls outdated view".split()),
    "ruff": frozenset("check".split()),
}

# Attachment types that make up the CONTEXT FLOOR -- what every turn pays before
# any work happens. `floor` decomposes the floor into exactly these components,
# which is the decomposition the 2026-08-23 findings reported.
#
# Each maps to the human label the finding used. An attachment type NOT listed
# here is still counted by `attachments` (which enumerates whatever it finds);
# it is only the floor breakdown that is a fixed vocabulary, because a floor
# whose categories drift cannot be compared across two measurements.
FLOOR_COMPONENTS = {
    "prompt_snapshot": "system prompt + tool schemas",
    "instructions": "CLAUDE.md / instructions",
    "skill_listing": "skill listing",
    "agent_listing_delta": "agent listing",
    "mcp_instructions_delta": "MCP instructions",
    "session_context": "session context",
    "memory": "memory bundle",
}


def _require_python() -> None:
    """Fail loud on an unsupported interpreter rather than emit wrong numbers."""
    if sys.version_info < MIN_PYTHON:
        want = ".".join(str(p) for p in MIN_PYTHON)
        have = ".".join(str(p) for p in sys.version_info[:3])
        sys.exit(
            f"token-attribute: needs Python >= {want}, got {have}.\n"
            f"Install a newer python3 or run via the sibling "
            f"token-attribute.sh shim."
        )


def transcript_root() -> pathlib.Path:
    return pathlib.Path.home() / ".claude" / "projects"


def _iter_records(jsonl: pathlib.Path):
    """Yield each parseable JSON record of a transcript, skipping junk lines.

    A transcript being written while this runs can end mid-line, and an
    unparseable line is not a reason to abandon the other thousands. Same
    degradation the sibling tools take.
    """
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
    permits the latter for a text-only turn and real transcripts contain both.
    Returning [] for the string shape would silently drop content, which is the
    wrong-but-quiet failure this tool exists to avoid.
    """
    content = (record.get("message") or {}).get("content")
    if isinstance(content, list):
        return content
    if isinstance(content, str) and content:
        return [{"type": "text", "text": content}]
    return []


def _text_of(block: dict) -> str:
    """Flatten a block's payload to text for sizing."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if content is not None:
        return json.dumps(content)
    text = block.get("text")
    return text if isinstance(text, str) else json.dumps(block)


def _usage(record: dict) -> dict:
    """Pull the usage block, which sits under `message` on assistant records."""
    return (record.get("message") or {}).get("usage") or record.get("usage") or {}


def _thinking_tokens(usage: dict) -> int:
    """Thinking tokens, from usage -- TRAP 3.

    They live in `usage.output_tokens_details.thinking_tokens`. The `thinking`
    CONTENT blocks carry empty strings, so any character count over content
    returns 0 and silently hides 55-86% of a subagent's output. There is
    deliberately no fallback to measuring the blocks: a fallback would make the
    wrong answer reachable again.
    """
    details = usage.get("output_tokens_details") or {}
    if not isinstance(details, dict):
        return 0
    value = details.get("thinking_tokens", 0)
    return value if isinstance(value, int) else 0


def parse_ts(raw: object, assume_tz: datetime.tzinfo) -> datetime.datetime | None:
    """Parse a transcript timestamp and normalize it to UTC -- TRAP 4.

    Transcript stamps are ISO-8601, usually with a trailing `Z`, but a NAIVE
    stamp (no offset) is legal and is the one that misfiles a whole band of
    runs: it is local wall-clock, while every gateway figure it will be compared
    against is UTC. Such a stamp is interpreted in `assume_tz` -- the zone the
    caller named with --tz -- and then converted, so the comparison is never
    between a local reading and a UTC one.

    Returns None for anything unparseable rather than raising: one bad stamp
    drops one record, it does not abandon the transcript.
    """
    if not isinstance(raw, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=assume_tz)
    return parsed.astimezone(datetime.timezone.utc)


def resolve_tz(name: str) -> datetime.tzinfo:
    """Resolve a --tz name to a tzinfo, failing loudly on an unknown zone.

    Explicit rather than defaulted to the machine's local zone: the whole point
    of TRAP 4 is that an unstated zone is the one that gets mixed up, so the
    operator states it. `UTC` is accepted without needing tzdata, which keeps
    the common case working in a container with no zoneinfo installed.
    """
    if name.upper() == "UTC":
        return datetime.timezone.utc
    try:
        import zoneinfo

        return zoneinfo.ZoneInfo(name)
    except Exception as exc:  # noqa: BLE001 -- any resolution failure is fatal
        raise SystemExit(
            f"token-attribute: unknown timezone {name!r} ({exc}).\n"
            f"Pass an IANA name (e.g. America/New_York) or UTC."
        ) from exc


def main_sessions(root: pathlib.Path) -> list[pathlib.Path]:
    """Top-level session transcripts -- `<project>/<uuid>.jsonl`."""
    return sorted(p for p in root.glob("*/*.jsonl") if "subagents" not in p.parts)


def spawn_transcripts(root: pathlib.Path) -> list[pathlib.Path]:
    """Subagent transcripts, which live one level deeper under `subagents/`."""
    return sorted(
        p for p in root.rglob("subagents/**/*.jsonl") if p.name != "journal.jsonl"
    )


def iter_turns(jsonl: pathlib.Path, assume_tz: datetime.tzinfo) -> list[dict]:
    """Group a transcript's lines into TURNS -- TRAPS 1 and 2, together.

    Claude Code writes one line per assistant CONTENT BLOCK. Every line of a
    turn repeats that turn's identical `usage`, and each line carries a
    DIFFERENT slice of the turn's blocks. So the two traps are really one shape
    with two halves:

      usage   read from ANY ONE line of the id. Summing per line is TRAP 1 and
              runs ~2x high.
      blocks  the UNION across every line of the id. Taking .[0] is TRAP 2 and
              loses most of the turn's tool calls.

    Doing both correctly is why this returns whole turns and why nothing else in
    this module reaches a record's blocks directly: there is no per-line path to
    the content, so the `.[0]` bug has nowhere to be reintroduced.

    Blocks are deduped WITHIN a turn by identity where they have one (tool_use
    and tool_result carry ids), because the same block can legitimately appear
    on more than one line. Lines with no `message.id` -- user records,
    attachments, system events -- are each their own turn keyed by uuid, since
    there is nothing to group them by and they carry no usage to double-count.
    """
    turns: dict[str, dict] = {}
    order: list[str] = []

    for index, record in enumerate(_iter_records(jsonl)):
        message = record.get("message") or {}
        key = message.get("id")
        if not key:
            key = f"__line_{record.get('uuid') or index}"

        turn = turns.get(key)
        if turn is None:
            turn = {
                "id": key,
                "line_index": index,
                "role": message.get("role"),
                "type": record.get("type"),
                "model": message.get("model"),
                "session": record.get("sessionId") or record.get("session_id"),
                "timestamp": parse_ts(record.get("timestamp"), assume_tz),
                "is_sidechain": bool(record.get("isSidechain")),
                # Usage from the FIRST line carrying one. Every later line of
                # this id repeats it, so adding them is TRAP 1.
                "usage": {},
                "blocks": [],
                "records": [],
                "_seen_blocks": set(),
            }
            turns[key] = turn
            order.append(key)

        turn["records"].append(record)
        if not turn["usage"]:
            usage = _usage(record)
            if usage:
                turn["usage"] = usage
        if turn["model"] is None and message.get("model"):
            turn["model"] = message["model"]
        if turn["timestamp"] is None:
            turn["timestamp"] = parse_ts(record.get("timestamp"), assume_tz)

        # THE UNION (trap 2).
        for block in _blocks(record):
            marker = block.get("id") or block.get("tool_use_id")
            if marker:
                if marker in turn["_seen_blocks"]:
                    continue
                turn["_seen_blocks"].add(marker)
            turn["blocks"].append(block)

    result = [turns[key] for key in order]
    for turn in result:
        turn.pop("_seen_blocks", None)
    return result


def _tool_name_by_id(turns: list[dict]) -> dict[str, str]:
    """Map each tool_use id to its tool name, across a whole transcript.

    A tool_result names only the id it answers, so attributing a result's size
    to `Bash` rather than to `(unknown)` requires the call it came from -- which
    is in an earlier turn. Built once per transcript rather than re-scanned per
    result.
    """
    names: dict[str, str] = {}
    for turn in turns:
        for block in turn["blocks"]:
            if block.get("type") == "tool_use" and block.get("id"):
                names[block["id"]] = block.get("name") or "(unknown)"
    return names


def classify_bash(command: str) -> str:
    """Classify a Bash command as read / mutate / other.

    Splits on pipeline and list separators and classifies by each segment's head
    word: a command is `mutate` if ANY segment mutates, `read` if every
    classified segment reads, and `other` when no segment is recognized. The
    asymmetry is deliberate -- `git log | tee out.txt` writes a file, and the
    conservative reading is the one that cannot overstate the read share the
    finding quotes.
    """
    verdicts = set()
    for raw_segment in command.replace("&&", ";").replace("||", ";").split(";"):
        for piece in raw_segment.split("|"):
            words = piece.split()
            # Strip leading env assignments (`FOO=bar cmd`) and shell prefixes
            # so the word classified is the real command. Without this the head
            # word of `command grep ...` is `command`, which is in neither set,
            # and the row lands in `other` -- and this repo's own scripts use
            # that prefix everywhere, so the miscount would be large.
            while words and ("=" in words[0] or words[0] in SHELL_PREFIXES):
                words = words[1:]
            if not words:
                continue
            head = words[0].split("/")[-1]
            sub = SUBCOMMAND_READ.get(head)
            if sub is not None:
                arg = next((w for w in words[1:] if not w.startswith("-")), "")
                verdicts.add("read" if arg in sub else "mutate")
            elif head in MUTATE_COMMANDS:
                verdicts.add("mutate")
            elif head in READ_COMMANDS:
                verdicts.add("read")
            else:
                verdicts.add("other")

    if "mutate" in verdicts:
        return "mutate"
    if "read" in verdicts:
        return "read"
    return "other"


# --- output -------------------------------------------------------------------


def emit(columns: list[str], rows: list[list], title: str) -> None:
    """Write the #781 TSV contract: `#` comments, then tab-separated rows.

    The first two columns are always window_start and model, which is what lets
    a consumer join these rows positionally against token-report.sh's window
    output -- gateway totals beside the transcript breakdown of the same window.
    """
    print(f"# token-attribute {title}")
    print("# columns: " + "\t".join(columns))
    for row in rows:
        print("\t".join(str(field) for field in row))


def _window_start(turns: list[dict]) -> str:
    """The earliest UTC timestamp in a turn list, as the join key.

    `-` when no turn carried a parseable stamp: an EMPTY field would collapse
    under a TSV reader's field split and shift every later column left, so the
    sentinel is a character rather than nothing.
    """
    stamps = [t["timestamp"] for t in turns if t["timestamp"]]
    if not stamps:
        return "-"
    return min(stamps).isoformat()


def _model_of(turns: list[dict]) -> str:
    """The dominant model across a turn list, or `-` when none is recorded."""
    counts = collections.Counter(t["model"] for t in turns if t["model"])
    return counts.most_common(1)[0][0] if counts else "-"


# --- subcommands ---------------------------------------------------------------


def cmd_debt(root: pathlib.Path, tz: datetime.tzinfo) -> int:
    """Per-tool re-read debt: result size x turns remaining.

    A tool result does not cost once. It is re-sent with every subsequent
    request for the rest of the session, so its real cost is its volume times
    how long it stays resident. This is the arithmetic behind "Bash carries 76%
    of all re-read debt" -- a figure no per-call size ranking produces, because
    an early medium result outweighs a late large one.
    """
    per_tool: dict[str, dict[str, int]] = collections.defaultdict(
        lambda: {"results": 0, "tokens": 0, "debt": 0}
    )
    all_turns: list[dict] = []

    for jsonl in main_sessions(root):
        turns = iter_turns(jsonl, tz)
        if not turns:
            continue
        all_turns.extend(turns)
        names = _tool_name_by_id(turns)
        total = len(turns)
        for index, turn in enumerate(turns):
            remaining = total - index
            for block in turn["blocks"]:
                if block.get("type") != "tool_result":
                    continue
                tokens = len(_text_of(block)) // CHARS_PER_TOKEN
                if tokens < RESULT_FLOOR_TOKENS:
                    continue
                tool = names.get(block.get("tool_use_id"), "(unknown)")
                entry = per_tool[tool]
                entry["results"] += 1
                entry["tokens"] += tokens
                entry["debt"] += tokens * remaining

    if not per_tool:
        print(
            f"token-attribute: no tool results over {RESULT_FLOOR_TOKENS} tokens "
            f"under {root}.",
            file=sys.stderr,
        )
        return 3

    window, model = _window_start(all_turns), _model_of(all_turns)
    total_debt = sum(e["debt"] for e in per_tool.values())
    rows = []
    for tool, entry in sorted(per_tool.items(), key=lambda kv: -kv[1]["debt"]):
        share = round(100.0 * entry["debt"] / total_debt, 1) if total_debt else 0.0
        rows.append(
            [
                window,
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
    )
    return 0


def cmd_floor(root: pathlib.Path, tz: datetime.tzinfo) -> int:
    """Context-floor decomposition: what every turn pays before any work.

    Reads the attachment records that carry the floor -- the system prompt and
    tool schemas, CLAUDE.md, the skill and agent listings -- and sizes each. The
    components are a FIXED vocabulary (FLOOR_COMPONENTS) rather than whatever
    the corpus happens to contain, because a floor whose categories drift
    between two runs cannot be compared, which is the question a floor
    measurement is asked.
    """
    sizes: dict[str, dict[str, int]] = collections.defaultdict(
        lambda: {"count": 0, "tokens": 0}
    )
    all_turns: list[dict] = []

    for jsonl in main_sessions(root):
        turns = iter_turns(jsonl, tz)
        all_turns.extend(turns)
        for turn in turns:
            for record in turn["records"]:
                if record.get("type") != "attachment":
                    continue
                attachment = record.get("attachment") or {}
                kind = attachment.get("type")
                if kind not in FLOOR_COMPONENTS:
                    continue
                entry = sizes[kind]
                entry["count"] += 1
                entry["tokens"] += len(json.dumps(attachment)) // CHARS_PER_TOKEN

    if not sizes:
        print(f"token-attribute: no floor attachments under {root}.", file=sys.stderr)
        return 3

    window, model = _window_start(all_turns), _model_of(all_turns)
    total = sum(e["tokens"] for e in sizes.values())
    rows = []
    for kind, entry in sorted(sizes.items(), key=lambda kv: -kv[1]["tokens"]):
        share = round(100.0 * entry["tokens"] / total, 1) if total else 0.0
        rows.append(
            [
                window,
                model,
                kind,
                FLOOR_COMPONENTS[kind].replace("\t", " "),
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
    )
    return 0


def cmd_growth(root: pathlib.Path, tz: datetime.tzinfo) -> int:
    """Per-decile cost growth within a session -- how the 3x was found.

    Splits each session into ten equal buckets of billed turns and reports the
    mean input context per turn in each. The headline is the last decile over
    the first: accumulated context means identical work costs multiples more
    late in a session than early, which is what motivates a size-triggered
    handoff (#784).
    """
    buckets: list[dict[str, int]] = [
        {"turns": 0, "input": 0, "output": 0, "thinking": 0}
        for _ in range(GROWTH_BUCKETS)
    ]
    all_turns: list[dict] = []

    for jsonl in main_sessions(root):
        turns = [t for t in iter_turns(jsonl, tz) if t["usage"]]
        if not turns:
            continue
        all_turns.extend(turns)
        total = len(turns)
        for index, turn in enumerate(turns):
            slot = min(index * GROWTH_BUCKETS // total, GROWTH_BUCKETS - 1)
            usage = turn["usage"]
            context = (
                usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
            )
            entry = buckets[slot]
            entry["turns"] += 1
            entry["input"] += context
            entry["output"] += usage.get("output_tokens", 0)
            entry["thinking"] += _thinking_tokens(usage)

    if not all_turns:
        print(f"token-attribute: no billed turns under {root}.", file=sys.stderr)
        return 3

    window, model = _window_start(all_turns), _model_of(all_turns)
    first = buckets[0]
    base = (first["input"] / first["turns"]) if first["turns"] else 0.0
    rows = []
    for index, entry in enumerate(buckets):
        mean = (entry["input"] / entry["turns"]) if entry["turns"] else 0.0
        ratio = round(mean / base, 2) if base else 0.0
        rows.append(
            [
                window,
                model,
                index + 1,
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
    )
    return 0


def cmd_prefix(root: pathlib.Path, tz: datetime.tzinfo) -> int:
    """Subagent prefix distribution across spawns.

    A spawn's prefix is the input context of its first billed turn -- the system
    prompt, tool schemas and dispatch prompt sent before it does any work. The
    distribution matters more than the mean: the break-even that decides whether
    to delegate is a median, and a long tail is what makes an average mislead.
    """
    prefixes: list[int] = []
    thinking_total = 0
    all_turns: list[dict] = []

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
            all_turns.append(turn)
            thinking_total += _thinking_tokens(usage)
            prefixes.append(context)
            break

    if not prefixes:
        print(f"token-attribute: no subagent spawns under {root}.", file=sys.stderr)
        return 3

    prefixes.sort()
    window, model = _window_start(all_turns), _model_of(all_turns)

    def pct(fraction: float) -> int:
        # Nearest-rank: the smallest value at or above `fraction` of the data.
        # `int(n * f)` is one rank too high and collapses p100 to the maximum.
        rank = max(0, min(len(prefixes) - 1, int(len(prefixes) * fraction + 0.5) - 1))
        return prefixes[rank]

    rows = [
        [
            window,
            model,
            len(prefixes),
            pct(0.5),
            pct(0.9),
            prefixes[0],
            prefixes[-1],
            sum(prefixes),
            thinking_total,
        ]
    ]
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
    )
    return 0


def cmd_bash_class(root: pathlib.Path, tz: datetime.tzinfo) -> int:
    """Bash command read-vs-mutate classification -- the 49%/67% split.

    Two shares, and they are different numbers: the share of CALLS that are
    read-only investigation, and the share of RESULT TOKENS those calls produce.
    The second is the larger one and the one that matters, because a read
    produces far more output than a mutation.
    """
    counts: dict[str, dict[str, int]] = collections.defaultdict(
        lambda: {"calls": 0, "tokens": 0}
    )
    all_turns: list[dict] = []

    for jsonl in main_sessions(root):
        turns = iter_turns(jsonl, tz)
        if not turns:
            continue
        all_turns.extend(turns)
        # Result sizes are attributed back to the call they answer, which is in
        # an earlier turn -- so index the results first, then walk the calls.
        results: dict[str, int] = {}
        for turn in turns:
            for block in turn["blocks"]:
                if block.get("type") == "tool_result" and block.get("tool_use_id"):
                    results[block["tool_use_id"]] = len(_text_of(block))
        for turn in turns:
            for block in turn["blocks"]:
                if block.get("type") != "tool_use" or block.get("name") != "Bash":
                    continue
                command = (block.get("input") or {}).get("command", "")
                verdict = classify_bash(command if isinstance(command, str) else "")
                entry = counts[verdict]
                entry["calls"] += 1
                entry["tokens"] += results.get(block.get("id"), 0) // CHARS_PER_TOKEN

    if not counts:
        print(f"token-attribute: no Bash calls under {root}.", file=sys.stderr)
        return 3

    window, model = _window_start(all_turns), _model_of(all_turns)
    total_calls = sum(e["calls"] for e in counts.values())
    total_tokens = sum(e["tokens"] for e in counts.values())
    rows = []
    for verdict in ("read", "mutate", "other"):
        entry = counts.get(verdict, {"calls": 0, "tokens": 0})
        rows.append(
            [
                window,
                model,
                verdict,
                entry["calls"],
                round(100.0 * entry["calls"] / total_calls, 1) if total_calls else 0.0,
                entry["tokens"],
                round(100.0 * entry["tokens"] / total_tokens, 1)
                if total_tokens
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
    )
    return 0


def cmd_attachments(root: pathlib.Path, tz: datetime.tzinfo) -> int:
    """Attachment-type volume -- how the no-op `hook_success` finding surfaced.

    Enumerates whatever attachment types the corpus contains, with count and
    total size. Unlike `floor` this vocabulary is OPEN on purpose: the finding
    it reproduces was a type nobody expected to be there at all, and a fixed
    list would have filtered exactly that discovery out.
    """
    sizes: dict[str, dict[str, int]] = collections.defaultdict(
        lambda: {"count": 0, "tokens": 0}
    )
    all_turns: list[dict] = []

    for jsonl in main_sessions(root) + spawn_transcripts(root):
        turns = iter_turns(jsonl, tz)
        all_turns.extend(turns)
        for turn in turns:
            for record in turn["records"]:
                if record.get("type") != "attachment":
                    continue
                attachment = record.get("attachment") or {}
                kind = attachment.get("type") or "(untyped)"
                entry = sizes[kind]
                entry["count"] += 1
                entry["tokens"] += len(json.dumps(attachment)) // CHARS_PER_TOKEN

    if not sizes:
        print(f"token-attribute: no attachments under {root}.", file=sys.stderr)
        return 3

    window, model = _window_start(all_turns), _model_of(all_turns)
    total = sum(e["tokens"] for e in sizes.values())
    rows = []
    for kind, entry in sorted(sizes.items(), key=lambda kv: -kv[1]["tokens"]):
        mean = entry["tokens"] // entry["count"] if entry["count"] else 0
        share = round(100.0 * entry["tokens"] / total, 1) if total else 0.0
        rows.append([window, model, kind, entry["count"], entry["tokens"], mean, share])
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
    )
    return 0


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
    args = parser.parse_args(argv)

    tz = resolve_tz(args.tz)
    root = args.root or transcript_root()
    if not root.is_dir():
        print(f"token-attribute: no transcript root at {root}", file=sys.stderr)
        return 3

    return SUBCOMMANDS[args.subcommand](root, tz)


if __name__ == "__main__":
    sys.exit(main())
