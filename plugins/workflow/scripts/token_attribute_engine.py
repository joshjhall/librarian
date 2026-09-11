"""token_attribute_engine -- shared transcript-reading engine for token-attribute.

The half of #788's tool that the six report functions all sit on: transcript
discovery, the turn grouping where TRAPS 1 and 2 live (`iter_turns`), timestamp
normalization (TRAP 4), thinking-token extraction (TRAP 3), Bash classification,
the window model, and the TSV `emit`.

SPLIT ON A MEASURED SEAM, not on a size rule alone. Two detectors disagreed
about whether one existed: check-decomposition's seam detector said "no
low-coupling seam found -- units are mutually referential", while the review
harness named the six cmd_* functions as a clean seam. The dependency graph was
measured before the move and settles it -- NO engine symbol references any
cmd_*, and no cmd_* references another, so the dependency is strictly one-way
(reports -> engine) with no cycle and nothing to drag along. The seam detector
was reading reference DENSITY, which is high here precisely because every report
sits on this engine; that is layering, not entanglement.

Keeping the engine here rather than beside the reports is deliberate: this is
where the four traps live, so it is the file a future reader is sent to, and it
must not be the file that grows a seventh report.

Imported by token_attribute_reports.py and by the token-attribute.py CLI.
Runtime: Python 3.11+. See token-attribute.py's header for the no-bash-fallback
decision and its reason.
"""

from __future__ import annotations

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
    # `gh` is NOUN-then-VERB (`gh pr view` / `gh pr merge`), so the read/write
    # distinction is in the SECOND word, not the first. Listing the nouns here
    # classified `gh pr merge` as a read — measured, and caught by a fixture.
    # The nouns that take a verb are resolved by GH_NOUNS below; what stays here
    # are the `gh` subcommands that are themselves terminal reads.
    "gh": frozenset("api browse search status".split()),
    "npm": frozenset("list ls outdated view".split()),
    "ruff": frozenset("check".split()),
}

# `gh <noun> <verb>`: nouns whose verb decides read-vs-write, and the verbs that
# only read. `gh pr view` reads; `gh pr merge`, `gh pr create` and `gh pr close`
# all change something on the remote, and collapsing them with `view` would put
# a merge in the "investigation" bucket the 49%/67% finding is about.
GH_NOUNS = frozenset("pr issue repo release run cache gist label workflow".split())
GH_READ_VERBS = frozenset("view list ls diff checks status download log".split())

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
                operands = [w for w in words[1:] if not w.startswith("-")]
                arg = operands[0] if operands else ""
                if head == "gh" and arg in GH_NOUNS:
                    # Noun-then-verb: the verb carries the meaning. A bare
                    # `gh pr` with no verb prints help, which is a read.
                    verb = operands[1] if len(operands) > 1 else "list"
                    verdicts.add("read" if verb in GH_READ_VERBS else "mutate")
                else:
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


def emit(columns: list[str], rows: list[list], title: str, window: "Window") -> None:
    """Write the #781 TSV contract: `#` comments, then tab-separated rows.

    The first two columns are always window_start and model, which is what lets
    a consumer join these rows positionally against token-report.sh's window
    output -- gateway totals beside the transcript breakdown of the same window.

    An UNSCOPED run prints a `# WARNING:` line saying the join key is descriptive
    rather than declared. The warning is not decoration: over a default
    ~/.claude/projects the scan spans months, so `window_start` is the operator's
    oldest transcript and matches no gateway window at all. That is a wrong
    number that reads as right -- the exact failure this tool exists to prevent
    -- so it must be said out loud in the output rather than left to the reader
    to infer. It is a `#` comment, so a consumer stripping /^#/ is unaffected.
    """
    print(f"# token-attribute {title}")
    if not window.declared:
        print(
            "# WARNING: no --since/--until given, so window_start is the earliest"
            " stamp SEEN, not a declared window. Pass --since/--until matching"
            " the token-report.sh window to make these rows joinable."
        )
    print("# columns: " + "\t".join(columns))
    for row in rows:
        print("\t".join(str(field) for field in row))


def _window_start(turns: list[dict], window: "Window") -> str:
    """The join key's first column: the WINDOW this scan covers.

    When the operator scoped the scan with --since, that boundary IS the window
    start and is returned verbatim -- which is what makes the row joinable
    against `token-report.sh window --start <same>`. Without --since there is no
    declared window, so the earliest stamp actually seen is reported instead and
    `emit` prints a `# WARNING:` naming the gap: over an unscoped
    ~/.claude/projects that stamp is the first transcript the operator ever
    wrote, which joins against nothing.

    `-` when no turn carried a parseable stamp: an EMPTY field would collapse
    under a TSV reader's field split and shift every later column left, so the
    sentinel is a character rather than nothing.
    """
    if window.since is not None:
        return window.since.isoformat()
    stamps = [t["timestamp"] for t in turns if t["timestamp"]]
    if not stamps:
        return "-"
    return min(stamps).isoformat()


def _model_of(turn: dict) -> str:
    """One turn's model, or `-` when the record does not name one.

    PER TURN, deliberately. An earlier draft took the most-common model across
    the whole scan and stamped it on every row, which silently misattributed
    every other model's volume to the majority one -- the join column claiming a
    model that did not produce the number beside it. Grouping by this value is
    what keeps a multi-model corpus honest, so nothing here may collapse it.
    """
    return turn.get("model") or "-"


def _percentile(values: list[int], fraction: float) -> int:
    """Nearest-rank percentile: the smallest value at or above `fraction`.

    `values` must already be sorted ascending.

    The `+ 0.5) - 1` spelling is load-bearing and easy to "simplify" wrongly. A
    bare `int(n * fraction)` is one rank too high, which at n=10 collapses p90
    onto the MAXIMUM -- a p90 that silently equals the worst case reads as a
    plausible number, so the error hides. Module-level rather than nested in
    cmd_prefix so the gate can assert it against a known distribution directly.
    """
    if not values:
        return 0
    rank = max(0, min(len(values) - 1, int(len(values) * fraction + 0.5) - 1))
    return values[rank]


def _dominant_model(turns: list[dict]) -> str:
    """The most common model across a turn list.

    Used ONLY where the thing being attributed genuinely has no model of its own
    -- an attachment record, which is a property of the session rather than of a
    billed turn. Never used to label a turn that names its own model: that was
    the collapse this file was reviewed for.
    """
    counts = collections.Counter(t["model"] for t in turns if t["model"])
    return counts.most_common(1)[0][0] if counts else "-"


class Window:
    """The scan's declared time window: --since/--until, normalized to UTC.

    Exists so the window is a FIRST-CLASS input rather than something inferred
    from whatever files happened to be on disk. The gateway side of this join
    (`token-report.sh window --start X --end Y`) is always asked for an explicit
    window; the transcript side has to be able to answer for the same one.
    """

    def __init__(self, since=None, until=None):
        self.since = since
        self.until = until

    def contains(self, stamp) -> bool:
        """True when a turn belongs to this window.

        A turn with NO parseable timestamp is kept only on an unscoped run. Once
        a window is declared, an unplaceable turn cannot be shown to belong to
        it, and counting it would inflate the window's totals with volume from
        outside -- the same misattribution in the time axis that per-turn model
        grouping fixes in the model axis.
        """
        if self.since is None and self.until is None:
            return True
        if stamp is None:
            return False
        if self.since is not None and stamp < self.since:
            return False
        if self.until is not None and stamp >= self.until:
            return False
        return True

    @property
    def declared(self) -> bool:
        return self.since is not None or self.until is not None
