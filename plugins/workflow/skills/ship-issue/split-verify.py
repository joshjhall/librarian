#!/usr/bin/env python3
"""ship-issue — non-lossy split verification (Python primary implementation).

A reviewer that suggests a decomposition is cheap to ignore; a reviewer that
suggests one AND can PROVE the split lost nothing is cheap to accept. This tool
is that proof (issue #695, AC8).

Given the ORIGINAL file (pre-split, read from git or a copy) and the files it was
split INTO, it mechanically checks four properties:

  1. LOC CONSERVATION  — production LOC across the results ~= the original,
     modulo new import/mod/__init__ boilerplate (tolerance is configurable and
     defaults generously, because re-export scaffolding is real).
  2. UNIT PRESERVATION — every top-level unit present before is present after.
     This is the one that catches an actually-lost function.
  3. FAN-IN RESOLUTION — every unit that was REFERENCED before is still
     referenced-or-defined somewhere in the result set, so a call site cannot
     dangle.
  4. MARKDOWN REACHABILITY — every heading that MOVED out of a markdown file is
     reachable by a link from the original. A split that moves prose out but
     leaves no link has LOST content, not decomposed it — and that is the case
     the mechanical check is easiest to get wrong.

Usage:
    split-verify.py <original-file> <post-split-original> [<result-file> ...]

ARGUMENT CONTRACT. `<original-file>` is the PRE-split snapshot (typically
`git show HEAD:path > /tmp/before.ext`). The FIRST result argument is the
POST-split original — the same logical file after the split, which usually kept
part of its content. Remaining results are the files content moved INTO. The
first/rest distinction is load-bearing for the markdown check: a file linking to
itself proves nothing about reachability, so only the "moved into" files count
as link destinations.

Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty
  category is one of: split-loc-drift, split-unit-lost, split-fanin-dangling,
  split-heading-unreachable, split-verified

Exit codes:
  0 = verification ran (findings may or may not exist)
  1 = usage error, or a named file is missing
"""

from __future__ import annotations

import os
import re
import sys

# Reuse the sibling scanner's segmenters so "what is a unit" cannot drift between
# the tool that PROPOSES a split and the tool that VERIFIES one. Importing the
# sibling is safe here (same directory, same plugin) — unlike the cross-plugin
# case, which is why THAT sharing uses sentinel regions instead.
#
# ASSESSED AND KEPT AS AN IMPORT (#730 AC6). Sentinel regions are a workaround
# for a constraint that does not exist here: CLAUDE_PLUGIN_ROOT is plugin-scoped
# and the plugins declare no dependency on each other, so check-decomposition and
# ship-issue genuinely cannot share a module. These two files can. Deliberate
# duplication is strictly worse than an import whenever an import is available —
# it needs a gate, tamper fixtures, and a reviewer who remembers both copies
# exist. So this pair must NOT acquire `# >>> shared:` regions; the .sh halves
# use them only because bash has no import.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from sizing import (  # noqa: E402
    _int_env,
    emit,
    find_units,
    lang_of,
    measure,
)

TOKEN_RE = re.compile(r"[A-Za-z0-9_$]+")

# Markdown link/heading shapes. A moved heading counts as reachable when the
# original links either to the destination FILE or to the heading's anchor.
MD_HEADING_RE = re.compile(r"^(#{1,6})[ \t]+(.*)$")
MD_LINK_RE = re.compile(r"\]\(([^)]+)\)")


def read_lines(path: str) -> list[str]:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def md_headings(lines: list[str]) -> list[str]:
    """Heading TEXTS outside fenced code blocks, in file order."""
    out: list[str] = []
    fenced = False
    for line in lines:
        if line.startswith("```") or line.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = MD_HEADING_RE.match(line)
        if m:
            out.append(m.group(2).strip())
    return out


def md_anchor(text: str) -> str:
    """GitHub-style anchor slug for a heading, used to resolve `#anchor` links."""
    slug = text.lower()
    slug = re.sub(r"[^a-z0-9 \-]", "", slug)
    return slug.strip().replace(" ", "-")


def unit_names(lines: list[str], lang: str) -> set[str]:
    """Non-test top-level unit names.

    Markdown is EXCLUDED deliberately, and the reason OUTLIVED its original
    wording (#730). It used to be "find_units names every md unit 'section', so
    a set of them carries no identity"; md units are now slugged from their
    heading text, so they DO carry identity. The exclusion stands on the stronger
    ground underneath it: a heading that was reworded rather than lost would read
    as a lost unit here, and a set of slugs still cannot distinguish "moved" from
    "deleted". Markdown content is verified by the heading-reachability check
    instead, which compares real heading TEXT against the links left behind.
    """
    if lang == "md":
        return set()
    return set(u.name for u in find_units(lines, lang) if not u.is_test)


def referenced_tokens(lines: list[str]) -> set[str]:
    toks: set[str] = set()
    for line in lines:
        toks.update(TOKEN_RE.findall(line))
    return toks


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write(
            "Usage: split-verify.py <original-file> <post-split-original> "
            "[<result-file> ...]\n"
        )
        return 1

    original = argv[1]
    results = argv[2:]
    for path in [original] + results:
        if not os.path.isfile(path):
            sys.stderr.write(f"Error: file not found: {path}\n")
            return 1

    orig_lines = read_lines(original)
    orig_lang = lang_of(original)
    orig_units = find_units(orig_lines, orig_lang)
    orig_measure = measure(orig_lines, orig_lang, orig_units)
    orig_names = unit_names(orig_lines, orig_lang)

    # --- gather the result side ---------------------------------------------
    result_production = 0
    result_names: set[str] = set()
    result_tokens: set[str] = set()
    for path in results:
        lines = read_lines(path)
        lang = lang_of(path)
        units = find_units(lines, lang)
        result_production += measure(lines, lang, units)["production"]
        result_names |= unit_names(lines, lang)
        result_tokens |= referenced_tokens(lines)

    findings = 0

    # --- 1. LOC conservation -------------------------------------------------
    # Boilerplate allowance: a split adds imports, `mod` lines, __init__ re-exports.
    # Generous by default — the check exists to catch a LOST HALF, not to police
    # a few scaffold lines.
    tolerance = _int_env("SPLIT_LOC_TOLERANCE", 40)
    orig_production = orig_measure["production"]
    delta = result_production - orig_production
    if delta < -tolerance:
        findings += 1
        emit(
            original,
            1,
            "split-loc-drift",
            f"split lost {-delta} production LOC: {orig_production} before, "
            f"{result_production} across {len(results)} result file(s) "
            f"(tolerance {tolerance}) — content may have been dropped "
            f"rather than moved",
            "HIGH",
        )

    # --- 2. unit preservation ------------------------------------------------
    lost = sorted(orig_names - result_names)
    if lost:
        findings += 1
        shown = ", ".join(lost[:5])
        more = f" (+{len(lost) - 5} more)" if len(lost) > 5 else ""
        emit(
            original,
            1,
            "split-unit-lost",
            f"{len(lost)} top-level unit(s) present before the split are absent "
            f"after: {shown}{more}",
            "HIGH",
        )

    # --- 3. fan-in resolution ------------------------------------------------
    # A unit that is still CALLED in the result set but no longer DEFINED there
    # has a dangling call site: the caller survived the split, the callee did not.
    #
    # THE PREDICATE IS "referenced AND NOT defined", not "neither defined nor
    # referenced" (the shape this started as, which could never fire). A name that
    # is neither defined nor referenced after the split is simply GONE — real, but
    # already reported by check 2 as a lost unit, with nothing dangling behind it.
    # The genuinely dangerous case is the opposite: live callers pointing at a
    # definition that no longer exists, which is a broken split rather than an
    # incomplete one. It is reported IN ADDITION to check 2's lost-unit row,
    # because the two say different things to whoever fixes it.
    for name in sorted(orig_names):
        if name in result_names:
            continue
        if name not in result_tokens:
            continue
        findings += 1
        emit(
            original,
            1,
            "split-fanin-dangling",
            f"unit '{name}' is still referenced after the split but is no longer "
            f"defined in any result file — its callers dangle",
            "HIGH",
        )

    # --- 4. markdown reachability -------------------------------------------
    # The case the issue calls out: a split that moves prose out but leaves no
    # link has LOST content. Only meaningful when the original is markdown AND
    # something actually moved out of it.
    if orig_lang == "md":
        # CONTRACT: results[0] is the POST-SPLIT original — the file that kept
        # part of the content. It is read separately from `original` (the
        # pre-split snapshot, typically `git show HEAD:path`) because the two are
        # the same logical file at two points in time and so cannot share a path.
        post_lines = read_lines(results[0])
        surviving = set(md_headings(post_lines))
        moved = [h for h in md_headings(orig_lines) if h not in surviving]
        if moved:
            # Links present in the post-split original — the pointers that make
            # moved content reachable.
            link_targets = set()
            for line in post_lines:
                link_targets.update(MD_LINK_RE.findall(line))
            linked_files = set(
                os.path.basename(t.split("#")[0]) for t in link_targets if t
            )
            linked_anchors = set(t.split("#", 1)[1] for t in link_targets if "#" in t)

            # PER-HEADING DESTINATIONS, not a flattened set. Reachability is a
            # claim about ONE heading and the ONE file it landed in, so it must
            # be resolved per heading: which file received it, and does the
            # post-split original link to THAT file?
            #
            # The flattened form — "does the original link to any moved-into
            # file at all?" — passes a split where heading A moved into a linked
            # file and heading B moved into a file nothing points at: A's link
            # vouches for B, and the tool reports `split-verified` while B's
            # content is genuinely unreachable. That is precisely the loss this
            # check exists to catch, and it needed two destination files to
            # appear, which no fixture had.
            #
            # results[0] is the post-split original itself and is excluded: a
            # file linking to itself proves nothing about reachability.
            heading_dest = {}
            for path in results[1:]:
                if lang_of(path) != "md":
                    continue
                base = os.path.basename(path)
                for h in md_headings(read_lines(path)):
                    heading_dest.setdefault(h, base)

            unreachable = []
            for heading in moved:
                dest = heading_dest.get(heading)
                if dest is None:
                    # Present in no result file at all — lost outright.
                    unreachable.append(heading)
                    continue
                # It survived — but is it REACHABLE from the post-split original?
                if md_anchor(heading) in linked_anchors:
                    continue
                if dest in linked_files:
                    continue
                unreachable.append(heading)
            if unreachable:
                findings += 1
                shown = "; ".join(unreachable[:3])
                extra = len(unreachable) - 3
                more = f" (+{extra} more)" if extra > 0 else ""
                emit(
                    original,
                    1,
                    "split-heading-unreachable",
                    f"{len(unreachable)} heading(s) moved out of the original with "
                    f"no link left behind: {shown}{more} — progressive disclosure "
                    f"requires a one-line pointer, or the content is lost",
                    "HIGH",
                )

    if findings == 0:
        emit(
            original,
            1,
            "split-verified",
            f"split is non-lossy: {orig_production} -> {result_production} production "
            f"LOC across {len(results)} file(s), all {len(orig_names)} top-level "
            f"unit(s) preserved, no dangling references",
            "HIGH",
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
