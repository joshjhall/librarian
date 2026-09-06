"""Whole-bundle graph + health pass for check-okf-conformance (issue #669).

Slice A (patterns.py) asks a per-FILE question: does this document meet the OKF
schema floor? This module asks the questions that are properties of the BUNDLE
AS A GRAPH, which no per-file pass can answer:

  * memory-orphan          a concept no index names — written, never recallable
  * memory-dangling-index  an index line naming a file that is not there
  * memory-multi-index     one concept claimed by two indexes
  * memory-stale           past its own `stale_after`, or `status: deprecated`
  * memory-missing-why     a `type` whose configured body sections are absent

WHY THIS IS A SEPARATE MODULE. Two reasons, and the second is the load-bearing
one. (1) Size: patterns.py is at 369 production LOC against a 500 warning
budget, and inlining this would cross it. (2) The pass has a different SHAPE
from everything in patterns.py: it enumerates the bundle ROOT rather than
walking argv. See scan_bundle() for why that is required rather than merely
convenient.

THE PERMISSIVE RULE APPLIES UNCHANGED. Every category here is a FINDING AT
EXIT 0. OKF §11 forbids rejecting a bundle for broken cross-links or missing
indexes, and §12 asks for best-effort consumption; a health observation is even
further from a rejection than a conformance miss. Only the TOOL fails loud, and
this module has no tool-side failure of its own — an unreadable file is skipped,
an absent root produces nothing.

CERTAINTY CARRIES CONFORMANCE-VS-HEALTH. The skill now mixes a schema floor with
advisory health metrics, and a consumer must be able to tell a conformance
FAILURE from a health OBSERVATION without parsing the category name. The graph
categories are pure facts about files that exist, so they emit HIGH; the two
judgment categories emit MEDIUM as candidates for the LLM pass, the same way
check-lifecycle grades its deterministic rows. See contract.md § Kind.

bash parity: patterns.sh mirrors this file function-for-function in its
`# --- slice B: bundle graph + health ---` section. Keep the two in step; the
TSV is the contract and tests/validate-python-ports.sh diffs it.
"""

from __future__ import annotations

import fnmatch
import os
import re

# Category slugs — ONE literal each, mirrored by the C_* constants in
# patterns.sh. review-route.sh's _has_unsurfaceable_category must carry these
# exact names; #699 cycle 4 shipped three invented ones that could never match.
C_ORPHAN = "memory-orphan"
C_DANGLING_INDEX = "memory-dangling-index"
C_MULTI_INDEX = "memory-multi-index"
C_STALE = "memory-stale"
C_MISSING_WHY = "memory-missing-why"

# Evidence labels, likewise mirrored.
L_ORPHAN = "Concept is named by no index"
L_DANGLING = "Index names a file that does not exist"
L_MULTI = "Concept is named by more than one index"
L_STALE_DATE = "Memory is past its stale_after date"
L_STALE_DEPRECATED = "Memory is marked status: deprecated"
L_MISSING_WHY = "Body is missing a section required for this type"

# An index line's pointer to a concept. Markdown link target first
# (`[Title](some-file.md)`), then a bare `some-file.md` mention, so a plain-list
# index works as well as a linked one.
_MD_LINK_RE = re.compile(r"\]\(([^)]+\.md)\)")
_BARE_MD_RE = re.compile(r"(?<![(\w/-])([A-Za-z0-9._-]+\.md)")

# ISO date, the only shape compared. A malformed stale_after is NOT a finding:
# the frontmatter floor is slice A's business, and inventing a date rule here
# would reject a bundle for an unfamiliar spelling (§11).
_ISO_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

DEFAULT_INDEX_NAMES = ("MEMORY.md", "index.md", "index-*.md")

# OKF reserved files. `index.md` is ALSO a default index name above — that is
# not a conflict: it is reserved (slice A checks its §8 structure) AND it routes
# recall (this module reads its lines). `log.md` is reserved and routes nothing.
RESERVED = ("index.md", "log.md")


def read_index_names(path: str) -> list[str]:
    """Configured index basenames: $OKF_INDEX_NAMES -> thresholds.yml -> default.

    The env override is space-separated. An explicitly EMPTY override is
    honored as "no indexes configured", which read_config_list distinguishes
    from unset — see there.
    """
    env = os.environ.get("OKF_INDEX_NAMES")
    if env is not None and env.strip():
        return env.split()
    if env is not None:
        return []
    got = read_config_list(path, "index_names")
    return got if got is not None else list(DEFAULT_INDEX_NAMES)


def read_body_requirements(path: str) -> dict[str, list[str]]:
    """Per-type required body sections from `health.body_requirements`.

    Each entry is `<type> = <section> | <section>`. A type ABSENT from the
    config has NO requirement — the portability default. An unparseable entry is
    skipped rather than erroring: this is bundle-side config, and a malformed
    line must not turn a health scan into a tool failure.
    """
    out: dict[str, list[str]] = {}
    for entry in read_config_list(path, "body_requirements") or []:
        if "=" not in entry:
            continue
        name, _, spec = entry.partition("=")
        name = name.strip()
        sections = [s.strip() for s in spec.split("|") if s.strip()]
        if name and sections:
            out[name] = sections
    return out


def read_config_list(path: str, key: str) -> list[str] | None:
    """The `- item` list under `health.<key>` in thresholds.yml, or None when the
    key is absent entirely.

    None vs [] is a real distinction and the caller depends on it: an ABSENT key
    means "use the built-in default", while a key present with no items means
    "the operator configured none". Collapsing them would make it impossible to
    turn a rule off.

    The parse is deliberately tiny and mirrors read_pinned_version()'s shape in
    patterns.py — a full YAML parser would be a much larger surface for the two
    runtimes to disagree across, and this file's shape is fixed. Indentation is
    two-level: `health:` at column 0, `<key>:` indented, `- item` indented
    further. The top-level test is `line[0]` not being whitespace, matching the
    bash twin's glob rather than str.isalpha(), which is Unicode-aware where a
    bash glob is not (the #686 divergence).
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    in_health = False
    in_key = False
    found = False
    out: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line[0].isspace():
            # A column-0 line opens or closes the `health:` block, and always
            # ends any key block inside it.
            in_health = stripped.startswith("health:")
            in_key = False
            continue
        if not in_health:
            continue
        if stripped.startswith("- "):
            if in_key:
                # Strip an inline comment, then one layer of quotes — matching
                # how the values are actually written.
                item = stripped[2:]
                hash_at = item.find(" #")
                if hash_at >= 0:
                    item = item[:hash_at]
                out.append(item.strip().strip("\"'").strip())
            continue
        # Any other indented line is a key: it opens our block or closes it.
        in_key = stripped.startswith(key + ":")
        if in_key:
            found = True
    return out if found else None


def is_index(basename: str, index_names: list[str]) -> bool:
    """True when BASENAME routes recall.

    LITERAL EQUALITY IS TRIED FIRST, for every configured name, before any glob
    interpretation. A configured name is operator input, not a pattern language
    they opted into, so a name that simply IS the file must match — and a
    metacharacter-first order silently breaks that: `notes[1].md` reads as a
    character class, fails to match the file literally called `notes[1].md`, and
    the repo's only index is classified as a concept. Every one of its memories
    is then reported as an orphan while the index itself goes unread.

    Measured before fixing: `fnmatch('notes[1].md', 'notes[1].md')` is False,
    and bash's `case` agrees — so the two impls stayed in parity while both were
    wrong, which is exactly the shared-defect shape a parity gate cannot see.

    Only after literal equality fails is a name carrying a metacharacter treated
    as a pattern, which is what makes the `index-*.md` default work.
    """
    for name in index_names:
        if basename == name:
            return True
    for name in index_names:
        if any(ch in name for ch in "*?[") and fnmatch.fnmatch(basename, name):
            return True
    return False


def index_targets(lines: list[str]) -> list[tuple[str, int]]:
    """Every `<basename>.md` an index line points at, with its 1-based line.

    Markdown link targets first, then bare mentions on lines that had none, so a
    linked index and a plain-list index both work. Only the BASENAME is kept: an
    index may write `./foo.md` or `sub/foo.md` for the same concept, and the
    graph is keyed by basename throughout.
    """
    out: list[tuple[str, int]] = []
    for i, line in enumerate(lines, start=1):
        hits = _MD_LINK_RE.findall(line)
        if not hits:
            hits = _BARE_MD_RE.findall(line)
        for target in hits:
            out.append((target.rsplit("/", 1)[-1], i))
    return out


def frontmatter_fields(lines: list[str]) -> dict[str, str]:
    """Top-level frontmatter keys, plus `metadata.*` flattened as `metadata.key`.

    A tiny parse over the leading `---` block, not a YAML load, for the parity
    reason above. Nested keys are needed because OKF puts `status` /
    `stale_after` / `stale_check` under `metadata:` in this repo's bundles while
    another repo may put them at the top level — both spellings resolve here, so
    neither convention is privileged.

    Slice A owns unparseable frontmatter; this returns what it can and stays
    silent about the rest.
    """
    out: dict[str, str] = {}
    if not lines or lines[0].strip() != "---":
        return out
    prefix = ""
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if not line.strip() or line.strip().startswith("#"):
            continue
        indented = line[:1].isspace()
        stripped = line.strip()
        if ":" not in stripped:
            continue
        key, _, val = stripped.partition(":")
        key = key.strip()
        val = val.strip().strip("\"'").strip()
        if not indented:
            prefix = key + "." if not val else ""
            if val:
                out[key] = val
        elif prefix:
            out[prefix + key] = val
    return out


def field(fields: dict[str, str], name: str) -> str:
    """A frontmatter value by bare name, top level or under `metadata.`."""
    return fields.get(name, fields.get("metadata." + name, ""))


def today(injected: str = "") -> str:
    """The date staleness is judged against.

    $OKF_TODAY overrides it, and every fixture sets it — an acceptance criterion
    of #669. A staleness test pinned to the real clock stops testing what it
    claims the moment the date rolls past its fixture, and the failure mode is a
    silent false pass rather than a red test. Production falls back to the real
    date.
    """
    if injected:
        return injected
    env = os.environ.get("OKF_TODAY", "").strip()
    if env:
        return env
    import datetime

    return datetime.date.today().isoformat()


def scan_bundle(root: str, emit, thresholds_path: str) -> None:
    """Run the whole-bundle pass, emitting through the caller's `emit`.

    THE PASS ENUMERATES THE BUNDLE ROOT, NOT THE FILE LIST — this is the design
    point that makes it a different pass rather than more per-file rules. An
    orphan is "no index names this file", and the index may not be in the file
    list at all: a diff touching one concept must still be checkable against the
    index that should name it. So the file list gates WHETHER this pass runs
    (patterns.py calls it only when the list contained a bundle file); what it
    examines is the bundle on disk. split-verify.py:340-345 reads indexes from
    disk for the same reason and records the same argument.

    THE ROOT LEVEL ONLY, not a recursive walk — a deliberate scope limit rather
    than an oversight. OKF §8 gives each directory its own `index.md`, so a
    concept in `sub/` is routed by `sub/index.md`, and judging it against the
    ROOT index would report an orphan for every correctly-nested file. Checking
    each subdirectory against its own index is a coherent extension, but it is a
    different rule from the one this pass implements, so it stays out until
    someone needs it. Verified: a nested concept produces no orphan row.

    An absent or unreadable root produces nothing: "no bundle" is exit 0 with no
    findings, never an error.
    """
    if not root or not os.path.isdir(root):
        return

    index_names = read_index_names(thresholds_path)
    body_requirements = read_body_requirements(thresholds_path)
    now = today()

    try:
        entries = sorted(os.listdir(root))
    except OSError:
        return

    indexes: list[str] = []
    concepts: list[str] = []
    for name in entries:
        if not name.endswith(".md"):
            continue
        if not os.path.isfile(os.path.join(root, name)):
            continue
        if is_index(name, index_names):
            indexes.append(name)
        elif name not in RESERVED:
            # A reserved non-index file (log.md) is neither an index nor a
            # concept: §9 makes it a changelog, and calling it an orphan would
            # be a finding on every conformant bundle in existence.
            concepts.append(name)

    def read(name: str) -> list[str]:
        try:
            with open(
                os.path.join(root, name), "r", encoding="utf-8", errors="replace"
            ) as fh:
                return fh.read().splitlines()
        except OSError:
            return []

    # --- graph: orphan / dangling / multi-index ------------------------------
    # named[basename] = list of (index_file, line) naming it.
    named: dict[str, list[tuple[str, int]]] = {}
    for idx in indexes:
        seen_in_this_index: set[str] = set()
        for target, line_no in index_targets(read(idx)):
            if target in seen_in_this_index:
                # One index naming a concept twice is a duplicate LINE, not a
                # multi-index: multi-index is about two DIFFERENT indexes both
                # claiming ownership. Counting repeats would fire on any index
                # that mentions a file in both a heading and a list.
                continue
            seen_in_this_index.add(target)
            named.setdefault(target, []).append((idx, line_no))

    concept_set = set(concepts)
    index_set = set(indexes)

    for target in sorted(named):
        # An index pointing at another INDEX is ordinary structure (a root index
        # naming its sub-indexes — this repo's own MEMORY.md does exactly that),
        # so it is neither dangling nor multi-indexed.
        if target in index_set:
            continue
        sites = named[target]
        if target not in concept_set:
            src, line_no = sites[0]
            emit(
                os.path.join(root, src),
                line_no,
                C_DANGLING_INDEX,
                L_DANGLING + ": " + target,
                "HIGH",
            )
            continue
        if len(sites) > 1:
            where = ", ".join(s for s, _ in sites)
            emit(
                os.path.join(root, target),
                1,
                C_MULTI_INDEX,
                L_MULTI + ": " + where,
                "HIGH",
            )

    # A BUNDLE WITH NO INDEX HAS NO ORPHANS. §11 forbids rejecting a bundle for
    # missing index.md files, so a bundle that does not use indexes for routing
    # must not have every one of its concepts reported — that is the "fires on
    # everything" failure the healthy-bundle fixture exists to catch, and it
    # caught exactly this. An orphan is only meaningful once SOME index is doing
    # the routing; then a concept nobody named is a real gap.
    #
    # Guarded HERE rather than by an early return, because staleness and body
    # requirements below are per-file and hold whether or not the bundle indexes
    # anything.
    if indexes:
        for name in concepts:
            if name not in named:
                emit(os.path.join(root, name), 1, C_ORPHAN, L_ORPHAN, "HIGH")

    # --- health: staleness and body requirements -----------------------------
    for name in concepts:
        path = os.path.join(root, name)
        lines = read(name)
        fields = frontmatter_fields(lines)

        status = field(fields, "status")
        stale_after = field(fields, "stale_after")
        stale_check = field(fields, "stale_check")

        if status == "deprecated":
            emit(path, 1, C_STALE, L_STALE_DEPRECATED, "MEDIUM")
        elif _ISO_DATE_RE.match(stale_after) and stale_after < now:
            # QUOTE THE MEMORY'S OWN stale_check (#669): that field exists to
            # name the sentence to re-verify, so surfacing it turns "may be out
            # of date" into a specific instruction. Falls back to the date alone
            # when the memory did not write one.
            evidence = L_STALE_DATE + " (" + stale_after + ")"
            if stale_check:
                evidence += ": " + stale_check
            emit(path, 1, C_STALE, evidence, "MEDIUM")

        required = body_requirements.get(field(fields, "type"), [])
        if required:
            body = "\n".join(lines)
            missing = [s for s in required if s not in body]
            if missing:
                emit(
                    path,
                    1,
                    C_MISSING_WHY,
                    L_MISSING_WHY + ": " + ", ".join(missing),
                    "MEDIUM",
                )
