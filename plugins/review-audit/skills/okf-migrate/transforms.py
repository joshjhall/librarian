"""okf-migrate — transform bodies.

Split from migrate.py, which is the driver (CLI, bundle discovery, plan
rendering, the apply safety gates). This module holds the per-transform logic:
what each one would change, expressed as EDITS, never as writes.

THE CENTRAL CONTRACT: every function here is PURE with respect to the
filesystem. It reads files and returns Edit objects; it never writes one. The
driver is the only writer, and it writes only what a plan listed. That is what
makes `plan` a genuine preview rather than a rehearsal that might diverge — and
it is why an `apply` that discovered a new file would be a bug rather than a
permitted widening.

Each transform is deterministic and idempotent: run against its own output it
produces zero edits. The fixtures pin both properties (AC3, AC4).

Python 3.11+; mirrored by transforms.sh for the bash-3.2 fallback. The two must
agree on output — that is the language boundary, per CLAUDE.md § Runtime policy.
"""

from __future__ import annotations

import fnmatch
import os
import re

# A wikilink: `[[target]]` or `[[target|label]]`. Deliberately NOT `\w` — that
# is Unicode-aware in python and a LITERAL in BSD grep, so the bash twin would
# match nothing on macOS while this matched everything, silently (CLAUDE.md
# § Runtime policy (3)). The negated class keeps the two dialects agreeing.
WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]")

# A fenced code block delimiter. Wikilinks inside a fence are SAMPLE TEXT, not
# links — a memory documenting the old syntax (this repo has several) must not
# have its examples rewritten out from under it.
FENCE_RE = re.compile(r"^[ \t]*(```|~~~)")


class Edit:
    """One change to one file.

    `kind` is "create" or "replace-line". A create carries the whole body; a
    replace-line carries the 1-based line number, the old text and the new.
    `note` explains the edit in the plan output, which is what a reviewer reads
    before approving a bulk rewrite.
    """

    def __init__(
        self,
        transform: str,
        path: str,
        kind: str,
        line: int = 0,
        old: str = "",
        new: str = "",
        note: str = "",
    ) -> None:
        self.transform = transform
        self.path = path
        self.kind = kind
        self.line = line
        self.old = old
        self.new = new
        self.note = note


class Ambiguity:
    """A decision the engine refuses to make for you.

    Carries the file, why it is ambiguous, and the candidate values — so the
    human choosing is choosing from a real list rather than inventing one. The
    driver turns any of these into a non-zero exit that writes NOTHING.
    """

    def __init__(self, path: str, reason: str, candidates: list[str]) -> None:
        self.path = path
        self.reason = reason
        self.candidates = candidates


def read_lines(path: str) -> list[str]:
    """PATH's lines without terminators, or [] when unreadable.

    errors="replace" rather than a raise: a bundle may hold any encoding, and a
    migration engine that dies on one odd file has failed at the one job that
    matters across N repos. An unreadable file simply yields no edits.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return []
    # A lone `\r` is rewritten to `\n` by read() unless newline="" is set, and
    # str.splitlines() (which this replaced) splits on `\x0b`/`\x0c`/`\x1c`-
    # `\x1e`/U+2028/2029 too -- none of which the bash twin's grep treats as a
    # separator (#980). Drop only the trailing empty a final newline leaves.
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def frontmatter_span(lines: list[str]) -> tuple[int, int]:
    """(start, end) 0-based indices of the frontmatter delimiters, or (-1, -1).

    Mirrors parse_frontmatter() in check-okf-conformance/patterns.py closely
    enough to agree on what a block IS, without reproducing its error taxonomy:
    this engine only needs to know where the block is, not to grade it. The
    validator owns grading.
    """
    if not lines or lines[0].strip() != "---":
        return (-1, -1)
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return (0, idx)
    return (-1, -1)


def frontmatter_keys(lines: list[str]) -> dict[str, str]:
    """Frontmatter keys mapped to raw values, including DOTTED paths for nested
    keys (`metadata.type`).

    The dotted spelling is what makes the commonest real migration expressible
    as configuration: a bundle whose `type` is nested under `metadata:` has the
    answer already written down, and a `frontmatter:metadata.type` rule reads it
    rather than guessing. Depth is tracked by indentation width, which is all
    the shape these files actually use.
    """
    start, end = frontmatter_span(lines)
    if start < 0:
        return {}
    keys: dict[str, str] = {}
    # (indent, name) of each open parent, outermost first.
    stack: list[tuple[int, str]] = []
    for idx in range(start + 1, end):
        line = lines[idx]
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("- "):
            continue
        if ":" not in stripped:
            continue
        indent = len(line) - len(line.lstrip())
        name = stripped.split(":", 1)[0].strip()
        value = stripped.split(":", 1)[1].strip()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        dotted = ".".join([p[1] for p in stack] + [name])
        if dotted not in keys:
            keys[dotted] = value
        if not value:
            stack.append((indent, name))
    return keys


def strip_quotes(value: str) -> str:
    """VALUE with one layer of surrounding quotes removed."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


# --- adopt-bundle ------------------------------------------------------------


def adopt_bundle(
    root: str, concepts: list[str], version: str, title: str
) -> list[Edit]:
    """Create the bundle-root index.md that declares this an OKF bundle.

    IDEMPOTENT BY CONSTRUCTION: an existing index.md is never rewritten, so a
    second run plans nothing. That is deliberate rather than incidental — the
    file is the operator's, and a transform that regenerated it would silently
    discard hand-written index lines on every run.

    ROOT-LEVEL CONCEPTS ONLY, and this is load-bearing. OKF §8 gives each
    DIRECTORY its own index.md, so a concept in `sub/` is routed by
    `sub/index.md` — never by the root index. Naming nested concepts here would
    be wrong twice over: it claims a routing relationship §8 does not define,
    and the validator's health pass (which enumerates the root level only, by
    the same §8 reasoning) reports every such line as memory-dangling-index.
    Measured before fixing: a bundle with one nested concept produced a dangling
    row for it immediately after a clean apply — this engine writing a bundle
    its own validator then faulted.

    Generating the per-directory indexes §8 describes is a coherent extension
    and a different transform; it stays out until someone needs it.

    Silent when the bundle has no root-level concepts: declaring an empty
    directory a bundle is noise, not adoption.
    """
    index = os.path.join(root, "index.md")
    if os.path.exists(index):
        return []
    top = [p for p in concepts if os.path.dirname(os.path.relpath(p, root)) == ""]
    if not top:
        return []
    body = [
        "---",
        "okf_version: " + version,
        "---",
        "",
        "# " + title,
        "",
    ]
    for path in sorted(top):
        rel = os.path.relpath(path, root)
        body.append("- [" + rel[:-3] + "](" + rel + ")")
    return [
        Edit(
            "adopt-bundle",
            index,
            "create",
            new="\n".join(body) + "\n",
            note="declare the bundle at okf_version "
            + version
            + " and index "
            + str(len(top))
            + " root-level concept(s)",
        )
    ]


# --- backfill-type -----------------------------------------------------------


def parse_type_rules(raw: list[str]) -> list[tuple[str, str, str]]:
    """`<source>:<pattern> = <type>` strings into (source, pattern, type).

    Malformed entries are SKIPPED rather than fatal. A migration engine reading
    a consumer repo's hand-edited config must not die on one bad line — but note
    what a skipped rule costs: fewer matches, hence MORE ambiguities, hence more
    human choices. The failure direction is toward asking, never toward guessing.
    """
    out: list[tuple[str, str, str]] = []
    for item in raw:
        if "=" not in item or ":" not in item.split("=", 1)[0]:
            continue
        left, right = item.split("=", 1)
        source, pattern = left.split(":", 1)
        out.append((source.strip(), pattern.strip(), right.strip()))
    return out


def infer_type(
    path: str, root: str, lines: list[str], rules: list[tuple[str, str, str]]
) -> list[str]:
    """Candidate `type` values for PATH, first match wins, in listed rule order.

    Returns [] when nothing matches (ambiguous — nothing to offer) or a
    single-element list when a rule matches. Never returns more than one: the
    rules are ORDERED and first-match-wins, which is what makes the outcome
    deterministic and therefore reproducible between the two runtimes.
    """
    rel = os.path.relpath(path, root)
    directory = os.path.dirname(rel)
    basename = os.path.basename(rel)
    keys = frontmatter_keys(lines)
    for source, pattern, target in rules:
        if source == "frontmatter":
            if "=" in pattern:
                continue
            key = pattern
            if key in keys:
                value = strip_quotes(keys[key])
                if value:
                    # `$value` means "adopt what is already written down" — the
                    # nested-key case, which is not an inference at all.
                    return [value if target == "$value" else target]
            continue
        if source == "dir":
            probe = directory + "/" if directory else ""
            if directory and (
                fnmatch.fnmatch(probe, pattern) or fnmatch.fnmatch(directory, pattern)
            ):
                return [target]
            continue
        if source == "file":
            if fnmatch.fnmatch(basename, pattern):
                return [target]
    return []


def backfill_type(
    root: str,
    concepts: list[str],
    rules: list[tuple[str, str, str]],
    known_types: list[str],
) -> tuple[list[Edit], list[Ambiguity]]:
    """Add a top-level `type` to every concept lacking one.

    Returns (edits, ambiguities). AN AMBIGUOUS FILE PRODUCES NO EDIT — it
    produces an Ambiguity, which the driver turns into a non-zero exit that
    writes nothing at all (AC5). The engine does not guess, and it does not
    partially apply around the files it could not decide: a half-migrated bundle
    is harder to reason about than an unmigrated one.

    A file whose frontmatter is unparseable is LEFT ALONE. The validator reports
    it as okf-unparseable-frontmatter, and repairing arbitrary broken YAML is
    not a mechanical transform — inserting a key into a block whose shape we do
    not understand risks compounding the damage.
    """
    edits: list[Edit] = []
    ambiguities: list[Ambiguity] = []
    for path in sorted(concepts):
        lines = read_lines(path)
        start, end = frontmatter_span(lines)
        if start < 0:
            continue
        keys = frontmatter_keys(lines)
        if "type" in keys and strip_quotes(keys["type"]):
            continue
        candidates = infer_type(path, root, lines, rules)
        if len(candidates) != 1:
            ambiguities.append(
                Ambiguity(
                    path,
                    "no inference rule matched"
                    if not candidates
                    else "multiple rules matched",
                    known_types,
                )
            )
            continue
        value = candidates[0]
        if "type" in keys:
            # Present but empty — replace the line in place rather than adding a
            # second `type:` key, which would leave the file with two.
            for idx in range(start + 1, end):
                if (
                    lines[idx].strip().startswith("type:")
                    and not lines[idx][0].isspace()
                ):
                    edits.append(
                        Edit(
                            "backfill-type",
                            path,
                            "replace-line",
                            line=idx + 1,
                            old=lines[idx],
                            new="type: " + value,
                            note="fill empty type",
                        )
                    )
                    break
            continue
        edits.append(
            Edit(
                "backfill-type",
                path,
                "insert-line",
                line=start + 2,
                new="type: " + value,
                note="infer type: " + value,
            )
        )
    return (edits, ambiguities)


# --- wikilink-convert --------------------------------------------------------


def resolve_target(target: str, path: str, root: str) -> tuple[str, bool]:
    """(bundle-relative path, resolved) for a wikilink TARGET.

    `resolved` is False when no such file exists. The path is returned ANYWAY —
    the path the target WOULD occupy — because §6.1 tolerates a broken link as
    knowledge not yet written, so converting it is lossless and dropping it
    would destroy the fact that someone meant to link there (AC6).

    Resolution tries the sibling directory first, then the bundle root, which
    matches how wikilinks are actually written: unqualified, meaning "the
    concept called this", usually nearby.
    """
    name = target.strip()
    if not name:
        return ("", False)
    if not name.endswith(".md"):
        name += ".md"
    here = os.path.dirname(path)
    sibling = os.path.join(here, name)
    if os.path.exists(sibling):
        return (os.path.relpath(sibling, root), True)
    at_root = os.path.join(root, name)
    if os.path.exists(at_root):
        return (os.path.relpath(at_root, root), True)
    return (name, False)


def render_link(label: str, rel: str, form: str) -> str:
    """A markdown link to REL in the configured FORM.

    bundle_relative is §6.1's recommendation: `/`-rooted, so it survives a file
    moving within its subdirectory. `relative` is the `./` form for tooling that
    needs it.
    """
    if form == "relative":
        return "[" + label + "](./" + rel + ")"
    return "[" + label + "](/" + rel + ")"


def convert_wikilinks(
    root: str, files: list[str], form: str, convert_unresolvable: bool
) -> list[Edit]:
    """Rewrite `[[x]]` to the configured markdown link form.

    IDEMPOTENT: the output contains no `[[`, so a second pass matches nothing.

    FENCED CODE IS SKIPPED. A memory documenting the old syntax — this repo has
    several — would otherwise have its examples silently rewritten, turning
    documentation of a format into a claim about a different one.
    """
    edits: list[Edit] = []
    for path in sorted(files):
        lines = read_lines(path)
        in_fence = False
        for idx, line in enumerate(lines):
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence or "[[" not in line:
                continue
            changed = line
            for match in WIKILINK_RE.finditer(line):
                target = match.group(1)
                label = match.group(2) if match.group(2) else target
                rel, resolved = resolve_target(target, path, root)
                if not rel:
                    continue
                if not resolved and not convert_unresolvable:
                    continue
                changed = changed.replace(
                    match.group(0), render_link(label, rel, form), 1
                )
            if changed != line:
                edits.append(
                    Edit(
                        "wikilink-convert",
                        path,
                        "replace-line",
                        line=idx + 1,
                        old=line,
                        new=changed,
                        note="convert wikilink(s) to " + form + " markdown links",
                    )
                )
    return edits
