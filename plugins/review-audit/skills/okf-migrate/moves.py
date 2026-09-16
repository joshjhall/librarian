"""okf-migrate — the move-concept transform (issue #934, OKF slice J).

Split from transforms.py rather than added to it, and that is a measurement
rather than a preference: transforms.py had 136 production LOC of headroom
(364/500) when this was written and this body is ~190, which would have
projected it to 554 — over budget. migrate.py was ALREADY over (505/500), so it
gains only dispatch wiring. Same seam transforms.py itself represents: the
driver writes, the transform bodies decide.

WHAT THIS TRANSFORM IS FOR. OKF concept IDs are the bundle path minus `.md`
(spec §3), so nesting is native to the format and a flat bundle throws away the
one addressing mechanism OKF provides. Moving a file is trivial; what is not
trivial — and what nobody does correctly by hand across 225 files — is rewriting
every INBOUND link and every INDEX POINTER to follow it.

THE INDEX POINTER IS THE WHOLE RISK. A memory's index line is the only thing
that makes it recallable, so a move that leaves the pointer behind does not
break anything visibly: the file still exists, the bundle still passes a
file-level check, and the memory is simply never found again. That is #632's
recorded failure mode (16 memories written, never recallable) arriving by a new
route. An index is not special-cased here — it is just a file containing links,
so the single inbound-link pass covers both.

THE CENTRAL CONTRACT, inherited from transforms.py: every function here is PURE
with respect to the filesystem. It reads files and returns Edit objects; it
never writes one, never renames one, and never shells out to git. The driver is
the only writer.

Python 3.11+; mirrored by moves.sh for the bash-3.2 fallback. The two must agree
on output byte for byte — that is the language boundary, per CLAUDE.md
§ Runtime policy.
"""

from __future__ import annotations

import fnmatch
import os
import re

from transforms import Edit, read_lines

# A markdown link's target: the `(...)` of `[label](target)`. Deliberately not
# `\S` or `\w` — both are LITERALS in BSD grep, so the bash twin would match
# nothing on macOS while this matched everything, silently (CLAUDE.md § Runtime
# policy (3)). A negated class agrees across both dialects.
LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")

# A fenced code block delimiter. Same rule convert_wikilinks applies and for the
# same reason: a link inside a fence is SAMPLE TEXT. This repo's memories
# document link syntax constantly, and rewriting an example turns documentation
# of a format into a false claim about a bundle's contents.
FENCE_RE = re.compile(r"^[ \t]*(```|~~~)")


def parse_taxonomy_rules(raw: list[str]) -> list[tuple[str, str, str]]:
    """`<source>:<pattern> = <dir>` strings into (source, pattern, dir).

    The SAME grammar backfill-type's rules use, reusing its shape rather than
    inventing a second config dialect for the same toolset. Malformed entries
    are SKIPPED rather than fatal, and note which way that fails: a skipped rule
    means fewer files match, hence FEWER moves. The failure direction is toward
    leaving the bundle alone, never toward moving a file somewhere unintended.
    """
    out: list[tuple[str, str, str]] = []
    for item in raw:
        if "=" not in item or ":" not in item.split("=", 1)[0]:
            continue
        left, right = item.split("=", 1)
        source, pattern = left.split(":", 1)
        target = right.strip().strip("/")
        if not target:
            continue
        out.append((source.strip(), pattern.strip(), target))
    return out


def index_members(
    root: str, every: list[str], index_names: list[str]
) -> dict[str, list[str]]:
    """Map each concept's bundle-relative path to EVERY index file naming it.

    This is what makes "mirror the buckets we already have" expressible as
    config. Without it, describing librarian's own taxonomy would take 225
    hand-written filename globs — each one a chance to typo a destination — when
    the routing information is already written down in the index that points at
    the file.

    ALL NAMING INDEXES, NOT THE FIRST. A concept listed in both a root MEMORY.md
    and a topic index is ordinary (the root often summarises), and picking one by
    path sort would decide the destination by an alphabetical accident: measured
    on the first fixture written for this transform, `MEMORY.md` sorted ahead of
    `index-golem.md` and an `index:index-golem.md` rule silently matched nothing.
    Returning every index instead lets RULE ORDER arbitrate, which is the
    first-match-wins semantics the rest of this grammar already has, stated by
    the operator rather than by the filesystem.
    """
    members: dict[str, list[str]] = {}
    for path in sorted(every):
        if not is_index_name(os.path.basename(path), index_names):
            continue
        rel_index = os.path.relpath(path, root)
        here = os.path.dirname(path)
        in_fence = False
        for line in read_lines(path):
            # FENCED CODE IS SKIPPED, the same rule this file's other two link
            # scanners apply. An index documenting link syntax in a ``` block
            # would otherwise have its EXAMPLE read as a live pointer, routing a
            # concept by a bucket it was never actually filed under — and the
            # inconsistency was the kind that only shows up on one repo's data.
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for match in LINK_RE.finditer(line):
                target = match.group(2).strip()
                if not target.endswith(".md") or "://" in target:
                    continue
                if target.startswith("/"):
                    resolved = os.path.normpath(target.lstrip("/"))
                else:
                    resolved = os.path.normpath(
                        os.path.relpath(os.path.join(here, target), root)
                    )
                bucket = members.setdefault(resolved, [])
                if rel_index not in bucket:
                    bucket.append(rel_index)
    return members


def resolve_destination(
    rel: str,
    rules: list[tuple[str, str, str]],
    member_of: dict[str, list[str]],
) -> str:
    """The bundle-relative DIRECTORY for concept REL, or "" when no rule matches.

    Ordered, first-match-wins — the same determinism rule infer_type holds, and
    for the same reason: two runtimes must reach the same answer.

    A file with no matching rule STAYS PUT. That is deliberate and is why this
    transform needs no ambiguity channel: not matching is a complete answer
    ("this file is not part of the taxonomy"), unlike backfill-type where not
    matching leaves a required key unfilled.
    """
    base = os.path.basename(rel)
    directory = os.path.dirname(rel)
    for source, pattern, target in rules:
        if source == "index":
            for index_rel in member_of.get(rel, []):
                if fnmatch.fnmatch(os.path.basename(index_rel), pattern):
                    return target
            continue
        if source == "file":
            if fnmatch.fnmatch(base, pattern):
                return target
            continue
        if source == "dir":
            probe = directory + "/" if directory else ""
            if directory and (
                fnmatch.fnmatch(probe, pattern) or fnmatch.fnmatch(directory, pattern)
            ):
                return target
    return ""


def plan_moves(
    root: str,
    concepts: list[str],
    every: list[str],
    rules: list[tuple[str, str, str]],
    index_names: list[str],
) -> tuple[list[Edit], dict[str, str]]:
    """(move edits, old_rel -> new_rel) for every concept the taxonomy relocates.

    Returns the mapping as well as the edits because the caller needs it to
    rewrite inbound links, and recomputing it there would be a second chance to
    disagree with this one.

    NO RULES MEANS NO MOVES, exit 0, silent. An unconfigured repo — which is
    every repo on the day it installs this — must get "nothing to move" rather
    than a taxonomy this engine invented. The judgment is the config a human
    writes; the engine only executes it (AC10).

    A file already at its destination produces no edit, which is what makes the
    transform IDEMPOTENT by construction rather than by a second-pass check: run
    it against its own output and every concept already sits where the rules say
    it belongs (AC5).
    """
    if not rules:
        return ([], {})
    edits: list[Edit] = []
    mapping: dict[str, str] = {}
    member_of = index_members(root, every, index_names)
    taken: set = {os.path.relpath(p, root) for p in concepts}
    for path in sorted(concepts):
        rel = os.path.relpath(path, root)
        target_dir = resolve_destination(rel, rules, member_of)
        if not target_dir:
            continue
        new_rel = os.path.join(target_dir, os.path.basename(rel))
        if new_rel == rel:
            continue
        # A DESTINATION COLLISION IS SKIPPED, NEVER OVERWRITTEN. Two concepts
        # with the same basename routed to one directory would otherwise have
        # the second silently destroy the first — an unrecoverable loss of a
        # memory, from a tool whose whole premise is running against someone
        # else's bundle. Leaving the file put is visible in the next check run.
        #
        # LEXISTS, NOT the `taken` set alone. `taken` is built from `concepts`,
        # which deliberately EXCLUDES symlinks (collect_bundle's safety
        # boundary), so a symlink sitting at a destination path was invisible
        # here and the move planned normally. That is only a near-miss in this
        # runtime — os.rename(2) replaces the link node rather than following
        # it — but it is a live write-through in the bash twin, whose `mv`
        # fallback resolves the destination with stat(2) and DEREFERENCES:
        # measured, a destination symlinked to an external directory carried
        # the concept out of the bundle entirely, at exit 0.
        #
        # Checked at PLAN time rather than refused at apply time so the answer
        # stays the established collision policy — skip this one move, exit 0 —
        # rather than aborting a whole run over one occupied path. Planning it
        # away also keeps the two runtimes agreeing on the exit code, which an
        # apply-side refusal in one of them does not.
        if new_rel in taken or os.path.lexists(os.path.join(root, new_rel)):
            continue
        taken.add(new_rel)
        mapping[rel] = new_rel
        edits.append(
            Edit(
                "move-concept",
                path,
                "move",
                old=rel,
                new=new_rel,
                note="relocate into " + target_dir + "/ per the taxonomy",
            )
        )
    return (edits, mapping)


def _rewritten_target(target: str, here_rel: str, mapping: dict[str, str]) -> str:
    """TARGET rewritten for the move set, or "" when it needs no change.

    Handles BOTH live link forms, which is not a nicety: #671's wikilink-convert
    emits the `/`-rooted bundle-relative form, while this repo's MEMORY.md and
    index-*.md files were hand-written with plain relative targets. A rewriter
    that understood only one would leave every pointer in the other form
    dangling — and dangling index pointers are precisely the silent un-recall
    this transform exists to prevent.

    The OUTPUT form always matches the INPUT form. Converting link style is
    wikilink-convert's job (§6.1); a move transform that also restyled links
    would make its own diff unreviewable.
    """
    if "://" in target or not target.endswith(".md"):
        return ""
    rooted = target.startswith("/")
    if rooted:
        old_rel = os.path.normpath(target.lstrip("/"))
    else:
        here_dir = os.path.dirname(here_rel)
        old_rel = os.path.normpath(os.path.join(here_dir, target))
    if old_rel not in mapping:
        return ""
    new_rel = mapping[old_rel]
    if rooted:
        return "/" + new_rel
    # The REFERRING file may itself be moving, so the relative link is recomputed
    # from where that file will LAND, not from where it sits now. Missing this
    # breaks exactly the links between two files that move together — the common
    # case when a whole bucket relocates at once.
    new_here = mapping.get(here_rel, here_rel)
    new_here_dir = os.path.dirname(new_here)
    return os.path.relpath(new_rel, new_here_dir) if new_here_dir else new_rel


def plan_directory_indexes(
    root: str, every: list[str], mapping: dict[str, str]
) -> tuple[list[Edit], dict[str, str]]:
    """(index-creating edits, moved_index_line_by_concept) for each new directory.

    OKF §8 GIVES EACH DIRECTORY ITS OWN index.md, and that is what makes a nested
    concept reachable: a concept in `golem/` is routed by `golem/index.md`, never
    by the bundle root's index. Rewriting the ROOT pointer to `golem/thing.md`
    instead — the obvious-looking move — produces a bundle the validator
    correctly faults as memory-dangling-index, because the root index is not the
    thing that routes a nested file. Measured against the real validator: the §8
    shape emits zero findings and the rewritten-root-pointer shape emits one per
    moved concept.

    So a move does not merely REPOINT an index line, it RELOCATES it: the line
    leaves the root index and lands in the new directory's index, and the root
    gains one line naming the sub-index. That is why this returns the lines it
    claimed — the caller must delete them from wherever they came from, and a
    line rewritten in place AND copied here would leave the concept named twice
    (memory-multi-index, also a HIGH finding).

    An EXISTING directory index is APPENDED TO, never regenerated — the two
    halves are both required. Not regenerating follows adopt_bundle's rule for
    the bundle root and for the same reason: the file is the operator's, and
    rewriting it would silently discard hand-written lines. But appending is
    equally load-bearing, because the arriving concept's old index line is being
    repointed at this very index; skipping the append leaves the concept named
    by NO index at all. Measured: a move into a directory that already had an
    index produced a memory-orphan row on an otherwise clean apply.
    """
    if not mapping:
        return ([], {})
    # Which concepts landed in each new directory, and the line that named each.
    by_dir: dict[str, list[str]] = {}
    for new_rel in mapping.values():
        directory = os.path.dirname(new_rel)
        if not directory:
            continue
        by_dir.setdefault(directory, []).append(new_rel)

    claimed: dict[str, str] = {}
    for path in sorted(every):
        here = os.path.dirname(os.path.relpath(path, root))
        in_fence = False
        for line in read_lines(path):
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence or "](" not in line:
                continue
            for match in LINK_RE.finditer(line):
                target = match.group(2).strip()
                if "://" in target or not target.endswith(".md"):
                    continue
                if target.startswith("/"):
                    old_rel = os.path.normpath(target.lstrip("/"))
                else:
                    old_rel = os.path.normpath(os.path.join(here, target))
                if old_rel in mapping:
                    claimed.setdefault(mapping[old_rel], line)

    edits: list[Edit] = []
    for directory in sorted(by_dir):
        index_path = os.path.join(root, directory, "index.md")
        # A SYMLINKED directory index is NOT "existing" — the read path already
        # refuses to trust one, and trusting it here would plan an append that
        # writes THROUGH it to wherever it points.
        if os.path.exists(index_path) and not os.path.islink(index_path):
            # AN EXISTING DIRECTORY INDEX IS APPENDED TO, NEVER REGENERATED. The
            # file is the operator's and may hold hand-written lines, so it is
            # not rewritten — but it MUST gain a line for each arriving concept
            # or that concept is named by no index at all. Measured: moving into
            # a directory that already had an index left the moved file as a
            # memory-orphan, because the line naming it had been repointed at the
            # sub-index while the sub-index never learned about it.
            existing = read_lines(index_path)
            # THE ALREADY-NAMED SET, built ONCE and FENCE-AWARE, through the same
            # LINK_RE every other pass here uses. A substring test over the raw
            # text cannot skip a fence, so an index that DOCUMENTS the index-line
            # format ("```markdown / - [Thing](t.md)") read its own EXAMPLE as a
            # live pointer and suppressed the append, leaving the concept named
            # by nothing outside a code block — the same
            # fenced-example-as-a-live-claim defect index_members,
            # plan_directory_indexes and rewrite_inbound_links each already
            # guard against. Measured identically in the bash twin, so
            # byte-parity was blind to it.
            already_named: set[str] = set()
            _in_fence = False
            for _line in existing:
                if FENCE_RE.match(_line):
                    _in_fence = not _in_fence
                    continue
                if _in_fence:
                    continue
                for _match in LINK_RE.finditer(_line):
                    already_named.add(_match.group(2).strip())
            # ONE EDIT FOR THE WHOLE BLOCK, not one per arriving concept, and
            # that is a correctness requirement rather than tidiness. Edits to a
            # file are applied HIGHEST LINE FIRST (migrate.py apply_edits), and
            # each insert clamps against the GROWING list — so N separate
            # appends at len+1, len+2, len+3 land out of order: measured with
            # three concepts, `c1, c2, c3` was written as `c1, c3, c2`. Both
            # runtimes did it identically, so byte-parity could not catch it.
            #
            # A single insert carrying the ordered block has no interleaving to
            # get wrong, and it stays one edit however many concepts arrive.
            rendered_lines: list[str] = []
            for new_rel in sorted(by_dir[directory]):
                base = os.path.basename(new_rel)
                # ALREADY-NAMED MEANS A REAL LINK, not a substring. This tested
                # `(base)` anywhere in the file, so an index whose PROSE
                # mentions a filename in parentheses — "the concept file is
                # called (golem-thing.md) by convention", ordinary in a bundle
                # that documents its own naming — read as already present and
                # the arriving concept was appended nowhere. It is then named by
                # no index at all: the memory-orphan this module's header calls
                # THE WHOLE RISK, reached by the code meant to prevent it.
                # Measured, and IDENTICALLY in the bash twin, so byte-parity was
                # blind to it — the same shape as the append-ordering bug above.
                # An exact match against a PARSED target settles it: prose is
                # not a link, and neither is a fenced example.
                if base in already_named:
                    continue
                line = claimed.get(new_rel)
                rendered_lines.append(
                    _retarget_line(line, base)
                    if line
                    else "- [" + base[:-3] + "](" + base + ")"
                )
            if rendered_lines:
                edits.append(
                    Edit(
                        "move-concept",
                        index_path,
                        "insert-block",
                        line=len(existing) + 1,
                        # A REAL newline joins the lines here; the record-level
                        # escaping is the bash twin's problem, and python's Edit
                        # fields are not serialized. The `insert-block` KIND is
                        # what tells the apply path this payload is several
                        # lines, so a content `\n` is never mistaken for a
                        # separator (measured: a hook reading `matches \n and \t
                        # literally` was written as two lines before this).
                        new="\n".join(rendered_lines),
                        note="name "
                        + str(len(rendered_lines))
                        + " arriving concept(s) in the existing "
                        + directory
                        + "/ index",
                    )
                )
            continue
        body = ["# " + directory, ""]
        for new_rel in sorted(by_dir[directory]):
            base = os.path.basename(new_rel)
            line = claimed.get(new_rel)
            if line:
                # The ORIGINAL index line, retargeted to the sibling basename —
                # its hook text is the operator's prose and is what makes the
                # entry useful to recall against. Regenerating a bare link would
                # silently discard it.
                body.append(_retarget_line(line, base))
            else:
                body.append("- [" + base[:-3] + "](" + base + ")")
        edits.append(
            Edit(
                "move-concept",
                index_path,
                "create",
                new="\n".join(body) + "\n",
                note="create the §8 directory index for "
                + directory
                + "/ naming "
                + str(len(by_dir[directory]))
                + " moved concept(s)",
            )
        )
    return (edits, claimed)


def _retarget_line(line: str, base: str) -> str:
    """LINE with its first bundle-internal `.md` link target replaced by BASE."""
    for match in LINK_RE.finditer(line):
        target = match.group(2).strip()
        if "://" in target or not target.endswith(".md"):
            continue
        return line.replace(match.group(0), "[" + match.group(1) + "](" + base + ")", 1)
    return line


def is_index_name(base: str, index_names: list[str]) -> bool:
    """True when BASE names an index, per the CONFIGURED index_names.

    CONFIG, NOT CONVENTION, and this is a portability requirement rather than a
    nicety: the epic's premise is running against SOMEONE ELSE'S bundle, and
    check-okf-conformance already reads `index_names` from thresholds.yml. A
    hardcoded `MEMORY.md`/`index*` test meant a repo whose index is called
    `catalog.md` got "nothing to move" from the `index:` rule source — measured,
    silently, at exit 0.

    LITERAL EQUALITY FIRST, then glob — the same ordering (and the same reason)
    the validator's is_index documents: a configured name is operator input, not
    a pattern language they opted into, so `notes[1].md` must match the file
    literally called that rather than being read as a character class.
    """
    for name in index_names:
        if base == name:
            return True
    for name in index_names:
        if fnmatch.fnmatch(base, name):
            return True
    return False


def rewrite_inbound_links(
    root: str,
    every: list[str],
    mapping: dict[str, str],
    relocated: dict[str, str] | None = None,
    index_names: list[str] | None = None,
) -> list[Edit]:
    """Rewrite EVERY inbound reference to a moved file, bundle-wide.

    "Every" is the acceptance criterion (AC3) and the reason this is a
    whole-bundle pass rather than a per-moved-file one: a file linked from two
    different directories must have BOTH references rewritten, and a rewriter
    that stopped at the first hit would leave the second dangling while the
    fixture that only checked one still passed.

    Indexes are not special-cased (AC4). An index is a file containing links, so
    one pass satisfies both criteria and there is no second code path to drift.
    """
    if not mapping:
        return []
    # An index line that was RELOCATED into a new directory index must not also
    # be repointed here: the concept would then be named by two indexes, which is
    # memory-multi-index — a HIGH finding, and a real ambiguity about which index
    # owns the concept.
    sub_index_of = {
        os.path.dirname(new_rel): new_rel
        for new_rel in (relocated or {})
        if os.path.dirname(new_rel)
    }
    edits: list[Edit] = []
    for path in sorted(every):
        here_rel = os.path.relpath(path, root)
        in_fence = False
        for idx, line in enumerate(read_lines(path)):
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence or "](" not in line:
                continue
            # ONLY AN INDEX RELOCATES A LINE. The claimed map is keyed by line
            # TEXT, so an ordinary body line that happens to equal a claimed
            # index line would otherwise be repointed at the bucket's
            # `index.md` instead of following the concept. Measured: two
            # concepts moving together, one linking the other, had that link
            # rewritten to `moved/index.md` — a link to the wrong file, from a
            # transform whose whole purpose is keeping links correct.
            #
            # Gating on the FILE rather than tightening the key is the honest
            # fix: "this line is an index entry" is a property of where it
            # lives, not of what it says.
            #
            # AND THE FILE GATE IS THE WHOLE TEST — the text key is gone. It was
            # kept alongside for one revision and was actively wrong: `claimed`
            # holds ONE line per moved concept (the first seen, alphabetically),
            # so when TWO indexes name the same concept with DIFFERENT hooks —
            # a terse root summary and a longer topic-index line, ordinary in
            # this repo's own bundle — only the first matched. The second fell
            # through to the generic rewrite and was repointed straight at the
            # concept, which is the memory-dangling-index the real validator
            # then reports. Identical in both runtimes, so byte-parity was blind.
            # The decision belongs to WHERE the line lives plus WHAT it resolves
            # to (`directory in sub_index_of`, below), never to its prose.
            if is_index_name(os.path.basename(here_rel), index_names or []):
                # This line's concept now lives in a directory index. Repoint it
                # at that SUB-INDEX (§8's routing: the root names the bucket, the
                # bucket names its concepts) rather than at the concept itself.
                directory = ""
                for match in LINK_RE.finditer(line):
                    target = match.group(2).strip()
                    if "://" in target or not target.endswith(".md"):
                        continue
                    if target.startswith("/"):
                        old_rel = os.path.normpath(target.lstrip("/"))
                    else:
                        old_rel = os.path.normpath(
                            os.path.join(os.path.dirname(here_rel), target)
                        )
                    directory = os.path.dirname(mapping.get(old_rel, ""))
                    break
                if directory and directory in sub_index_of:
                    changed = _retarget_line(line, directory + "/index.md")
                    if changed != line:
                        edits.append(
                            Edit(
                                "move-concept",
                                path,
                                "replace-line",
                                line=idx + 1,
                                old=line,
                                new=changed,
                                note="point at the §8 directory index for "
                                + directory
                                + "/",
                            )
                        )
                    continue
            changed = line
            for match in LINK_RE.finditer(line):
                new_target = _rewritten_target(
                    match.group(2).strip(), here_rel, mapping
                )
                if not new_target:
                    continue
                changed = changed.replace(
                    match.group(0),
                    "[" + match.group(1) + "](" + new_target + ")",
                    1,
                )
            if changed != line:
                edits.append(
                    Edit(
                        "move-concept",
                        path,
                        "replace-line",
                        line=idx + 1,
                        old=line,
                        new=changed,
                        note="follow moved concept(s) to their new path",
                    )
                )
    return edits
