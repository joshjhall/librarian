#!/usr/bin/env python3
"""Prose classification + bundle seams — the shared prose half of the sizing scanners.

Extracted from the entry scanner in #772 for the same reason as the sibling
loc_engine.py: both entry files were over the 800 production-LOC py budget and
could not be split until the sync gate learned multi-file pair members.

WHY THIS IS A SIBLING MODULE AND NOT A SHARED LIBRARY: see loc_engine.py. The
two copies of this file are pinned byte-for-byte by
tests/validate-shared-scanner-sync.sh.

WHAT LIVES HERE: the shared `bloat-spec-py` and `bundle-seam-py` regions (named
without their sentinel markers on purpose — the gate counts marker occurrences
per file, so quoting one in prose would read as a second copy of the region)
— what a markdown file IS (a fact about
its path, which must not fork between the lenses) and where a memory bundle's
seams are. The per-type BUDGETS are shared; the DISPOSITION of a row is not, and
stays in each entry scanner: the audit lens reports length directly, the review
lens grades the same row by what the diff did to it.

Depends on loc_engine for `_int_env` and `md_slug`. That direction is
one-way — loc_engine imports nothing from here — so there is no cycle.

COLUMN-ZERO RULE applies here too; see loc_engine.py.
"""

from __future__ import annotations

import fnmatch as _fnmatch
import os
import re

from loc_engine import _int_env, md_slug


# >>> shared:bloat-spec-py (sync: check-decomposition/prose_spec.py)
# PROSE FILE-TYPE CLASSIFICATION — shared by BOTH lenses (#724).
#
# What a markdown file IS is a fact about its PATH, and a fact must not fork.
# Before #724 only the audit lens classified prose; the review lens sized every
# .md by the generic md pair (700/1000), so an over-budget agent definition
# passed a per-PR review silently while the audit sweep called it HIGH. The two
# lenses may differ in STRICTNESS — that is a policy dial each owns — but they
# may not disagree about what the file is.
#
# STRICTNESS IS NOT FORKED EITHER, for these files specifically. Both lenses
# apply the bloat_thresholds numbers verbatim; there is no review-lens override
# table. The review lens is looser than the audit lens for CODE because those
# thresholds count production LOC and a per-PR gate that nags gets turned off.
# That argument does not transfer: bloat budgets are measured on TOTAL lines
# because these files load WHOLE into context, and that cost does not depend on
# which lens is looking. What keeps the review lens survivable here is its
# GROWTH DISPOSITION (sizing.py's scan_file), not a bigger number.
def _glob(path: str, pattern: str) -> bool:
    """`case "$path" in <pattern>)` — an unanchored shell glob over the full
    path. fnmatchcase's `*` crosses '/', matching bash `case` glob semantics."""
    return _fnmatch.fnmatchcase(path, pattern)


def _bundle_root() -> str:
    """The configured memory-bundle root, normalized for glob matching (#700).

    Configurable rather than hardcoded, defaulting to `.claude/memory`. An
    EMPTY value means no bundle is configured: memory classification is off and
    nothing errors.

    Normalization strips a leading `./` and any trailing `/` so that every
    spelling of the same root — `.claude/memory`, `./.claude/memory`,
    `.claude/memory/` — decides alike. An unnormalized root would make the
    glob miss, the file would fall back to the code thresholds, and the scan
    would still exit 0 — the silent fail-open this issue exists to close."""
    root = os.environ.get("MEMORY_BUNDLE_ROOT", ".claude/memory").strip()
    while root.startswith("./"):
        root = root[2:]
    while root.endswith("/"):
        root = root[:-1]
    return root


def bundle_kind(path: str) -> str:
    """Which half of the memory bundle PATH is: "index", "concept", or "" when
    it is not a bundle markdown file (#700).

    Only `*.md` under the root is bundle prose — a `.sh` or `.py` sitting in a
    bundle is code and keeps the code thresholds.

    An index is the file loaded every session to route recall: the root
    `MEMORY.md`, a topic sub-index `index-*.md`, or OKF's `index.md`."""
    root = _bundle_root()
    if not root:
        return ""
    # LITERAL containment, deliberately NOT _glob(). The root is operator
    # configuration, and routing it through fnmatch would interpret any glob
    # metacharacter in it (`[`, `]`, `*`, `?`) as syntax. The bash mirror does
    # NOT: a QUOTED expansion in a `case` pattern (`"$MEMORY_BUNDLE_ROOT"/*.md`)
    # is matched literally by bash. So a root like `weird[x]root` made fnmatch
    # read `[x]` as a character class and miss, while bash matched — the two
    # impls disagreed on the same file, breaking the byte-identical TSV
    # contract, silently and at exit 0. These two tests mirror bash's two arms:
    # `"$ROOT"/*` (root at the start) and `*/"$ROOT"/*` (root nested anywhere).
    if not (path.startswith(root + "/") or ("/" + root + "/") in path):
        return ""
    base = path.rsplit("/", 1)[-1]
    if not base.endswith(".md"):
        return ""
    if base == "MEMORY.md" or base == "index.md" or base.startswith("index-"):
        return "index"
    return "concept"


def bloat_spec(path: str) -> tuple[int, int, str, str] | None:
    """The per-file-type bloat thresholds, migrated verbatim from
    check-ai-config so the move is behavior-preserving. Returns
    (warn, high, file-type label, category) or None when the path is not an
    AI-instruction or documentation file.

    The memory-bundle arm is FIRST (#700): inside a configured bundle, bundle
    rules apply, so a `docs/` or `agents/` directory nested in the bundle
    cannot escape to the arms below and be sized by the wrong budget."""
    kind = bundle_kind(path)
    if kind == "index":
        return (
            _int_env("MEMORY_INDEX_WARN", 150),
            _int_env("MEMORY_INDEX_HIGH", 250),
            "memory index",
            "ai-file-bloat",
        )
    if kind == "concept":
        return (
            _int_env("MEMORY_CONCEPT_WARN", 200),
            _int_env("MEMORY_CONCEPT_HIGH", 350),
            "memory concept",
            "ai-file-bloat",
        )
    if _glob(path, "*/CLAUDE.md") or _glob(path, "*/AGENTS.md"):
        return (
            _int_env("CLAUDE_MD_WARN", 400),
            _int_env("CLAUDE_MD_HIGH", 600),
            "CLAUDE.md",
            "ai-file-bloat",
        )
    if _glob(path, "*/skills/*/SKILL.md"):
        return (
            _int_env("SKILL_WARN", 300),
            _int_env("SKILL_HIGH", 500),
            "skill definition",
            "ai-file-bloat",
        )
    if _glob(path, "*/agents/*/*.md") or _glob(path, "*/agents/*.md"):
        # Both agent layouts: the FLAT agents/<name>.md Claude Code discovers,
        # and the nested agents/<name>/<name>.md a harness-bearing agent uses.
        return (
            _int_env("AGENT_WARN", 250),
            _int_env("AGENT_HIGH", 400),
            "agent definition",
            "ai-file-bloat",
        )
    if _glob(path, "*/skills/*/*.md"):
        # Skill COMPANION prose (#589) — a reference file a SKILL.md tells the
        # agent to load. MUST stay below the SKILL.md arm above, which is the
        # narrower pattern: these arms are sequential, so hoisting this one
        # would swallow every SKILL.md into the looser companion budget.
        #
        # Before this arm existed, a companion matched NOTHING here and fell
        # through to the production-LOC code thresholds (300/500) — sized by a
        # rule written for source. Exactly the defect #700 fixed for memory
        # bundles, on the repo's LARGEST prose files.
        return (
            _int_env("COMPANION_WARN", 400),
            _int_env("COMPANION_HIGH", 650),
            "skill companion",
            "ai-file-bloat",
        )
    if _glob(path, "*/docs/*.md"):
        return (
            _int_env("DOC_WARN", 500),
            _int_env("DOC_HIGH", 800),
            "documentation",
            "doc-file-bloat",
        )
    return None


# <<< shared:bloat-spec-py


# >>> shared:bundle-seam-py (sync: check-decomposition/prose_spec.py)
# BUNDLE SPLIT GUIDANCE — shared by BOTH lenses (#729).
#
# #700 taught the AUDIT lens that a memory bundle splits by its own shape, and
# suppressed the generic markdown heading-cluster seam for it. The REVIEW lens
# got neither half: on a PR growing `.claude/memory/MEMORY.md` it emitted the
# generic `split shape for memory index: progressive disclosure ...` row. Two
# distinct harms, and the second is the serious one:
#
#   * an index splits by TOPIC CLUSTER and a concept by EXTRACTING THE SECOND
#     LESSON; neither is a line range, so the generic row is wrong guidance
#     rather than merely vague — precisely what #700 removed from the audit lens.
#   * the concept row's anti-orphan clause vanished entirely. That sentence is
#     the one that prevents #697's documented failure: 16 memories on disk,
#     absent from the index — written, never recallable, nothing errors.
#
# WHAT IS SHARED IS THE ROW, NOT THE DISPOSITION. These functions RETURN rows
# instead of calling emit(), because the two lenses legitimately differ on which
# rows survive: the audit lens emits the LOW `declined:` rows (a backlog reader
# needs to see a file was examined and found unsplittable — silence there is
# indistinguishable from "not scanned"), while the review lens drops them and
# gates the rest on its growth disposition, exactly as its generic prose seam
# already does. Sharing emit() would have forced one policy on both.
#
# MODULE-LEVEL BY NECESSITY, not by style. The audit lens carried this branch
# INDENTED inside scan_file(), which cannot be a shared region at all:
# validate-shared-scanner-sync.sh strips leading whitespace before comparing,
# and Python indentation is semantic, so an indented fragment can compare equal
# across a real divergence. Column-zero defs make the strip a no-op.
def concept_dir(path: str) -> str:
    """Which directory an extracted memory-bundle concept belongs in (#713).

    The source file's OWN directory, not the bundle root. `bundle_kind()`
    explicitly supports a concept nested below the root (its `*/root/*` arm), and
    for `<root>/topics/two-lessons.md` a root-anchored target silently drops the
    `topics/` segment — advice that, followed literally, moves the extracted
    lesson out of its subdirectory instead of alongside the sibling it was
    extracted from. Deriving from the source path is what every other
    seam-target computation here does (`target_path()`).

    Deliberately NOT `target_path()` itself, which builds `dir/stem/prefix.ext`
    — a subdirectory named for the source file. That is right for a code family
    and wrong for a bundle: an extracted lesson is a flat SIBLING of the file it
    came from, never a child of it.

    A flat-bundle file already HAS the root as its own directory, so the common
    case is unchanged by this derivation — only a nested concept moves. The
    bundle-root fallback is therefore defensive and unreachable from the only
    call site: `bundle_kind()` sets a kind only for a path matching
    `<root>/...` or `.../<root>/...`, both of which contain a slash."""
    if "/" in path:
        return path.rsplit("/", 1)[0]
    return _bundle_root()


def bundle_sections(lines: list[str]) -> list[str]:
    """The topic clusters of a bundle markdown file (#700).

    NOT the same as `find_units`' top-level units. `find_units` takes the
    SHALLOWEST heading depth present, which for a normal bundle file is the
    lone `# Title` — so the `##` topic sections, which are exactly what an
    index splits along, would be invisible and every index would decline.

    The rule here is the shallowest depth that has at least TWO headings: a
    `# Title` + `## topics` file clusters by its `##`, and a file written with
    all-`##` sections and no title clusters by those same `##`. Falls back to
    the shallowest depth when nothing repeats (a genuinely unsplittable file)."""
    heads: list[tuple[int, str]] = []
    fenced = False
    for line in lines:
        if line.startswith("```") or line.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = re.match(r"^(#{1,6})[ \t]+(.*)$", line)
        if m:
            heads.append((len(m.group(1)), md_slug(m.group(2)) or "section"))
    if not heads:
        return []
    depths = sorted(set(d for d, _ in heads))
    chosen = depths[0]
    for d in depths:
        if sum(1 for hd, _ in heads if hd == d) >= 2:
            chosen = d
            break
    return [name for d, name in heads if d == chosen]


def bundle_seam_rows(path: str, lines: list[str], kind: str) -> list[tuple]:
    """The bundle-shaped seam rows for an OVER-BUDGET bundle file (#729).

    Returns `(category, evidence, certainty)` triples — never emits. The caller
    decides which survive (see the region header): the audit lens takes all of
    them, the review lens keeps only the actionable ones.

    `kind` is `bundle_kind(path)`'s verdict and is assumed non-empty; callers
    branch on it first, which is also what gives the bundle arm its precedence
    over every other arm (#700's ordering) — a `docs/` or `agents/` directory
    nested inside the bundle is still sized and split as a bundle.

    The concept row names the extraction target AND requires its index line in
    the same breath. That conjunction is the whole point: half-following it —
    extracting the lesson, skipping the index line — is exactly the silent loss
    (#697). `split-verify`'s `split-memory-orphan` check makes the requirement
    mechanically verifiable rather than advisory."""
    names = bundle_sections(lines)
    if kind == "index":
        if len(names) >= 2:
            return [
                (
                    "decomposition-seam",
                    "index split: %d topic clusters (%s) -> index-<topic>.md; "
                    "root keeps one pointer line per sub-index"
                    % (len(names), ", ".join(names[:5])),
                    "HIGH",
                )
            ]
        return [
            (
                "decomposition-seam",
                "declined: index has no topic clusters to split on "
                "(%d sections) — trim entries instead" % len(names),
                "LOW",
            )
        ]
    if len(names) >= 2:
        return [
            (
                "decomposition-seam",
                "concept split: extract %s to %s/%s.md AND add its index "
                "line (an extracted concept with no index line is an orphan)"
                % (names[1], concept_dir(path), names[1]),
                "HIGH",
            )
        ]
    return [
        (
            "decomposition-seam",
            "declined: single lesson — no second concept to extract "
            "(%d sections); tighten the prose instead" % len(names),
            "LOW",
        )
    ]


# <<< shared:bundle-seam-py
