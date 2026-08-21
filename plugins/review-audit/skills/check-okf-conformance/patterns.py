#!/usr/bin/env python3
"""check-okf-conformance — Deterministic Pre-Scan (Python primary implementation).

Answers ONE question about a memory bundle: is it a conformant Open Knowledge
Format bundle at the SCHEMA FLOOR? Graph health (orphans, index budgets),
semantic quality (near-duplicates), and migration are separate slices of the
OKF epic and deliberately out of scope here.

The floor is OKF §11, and it is small:

  1. every non-reserved `.md` has a parseable YAML frontmatter block,
  2. every such block carries a non-empty `type`,
  3. the reserved files (`index.md`, `log.md`) follow §8 / §9 when present.

TWO KINDS OF FAILURE, KEPT STRICTLY APART. This distinction is the whole design
and conflating it is how this lands wrong:

  * THE BUNDLE is never rejected. Spec §11 says a consumer MUST NOT reject a
    bundle for unknown `type` values, unrecognized extra keys, broken
    cross-links, or a missing `index.md`, and §12 says an unfamiliar declared
    version calls for best-effort consumption rather than refusal. So every
    conformance problem — including version drift — is a FINDING AT EXIT 0.
    Non-conformance is reported, never fatal.

  * THE TOOL fails loud. A missing/malformed version pin, a usage error, or an
    unreadable file list exits NON-ZERO with an actionable message, because a
    tool that cannot do its job must not report a clean bundle it never checked
    (the runtime policy, #538/#571).

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — parity is pinned by
tests/validate-python-ports.sh, and the classification behavior by
tests/validate-okf-detectors.sh. See CLAUDE.md § Key conventions.

ZERO LIBRARIAN-SPECIFIC VALUES. The reserved names are the spec's (`index.md`,
`log.md`) and nothing else. In particular this does NOT inherit
check-decomposition's `MEMORY.md` / `index-*.md` index heuristic: those are one
repo's naming convention, and a portable validator that hardcoded them would
mis-classify every other repo's bundle.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings) — including a non-conformant bundle
  1 = usage error, file list not found, or an unresolvable version pin
"""

from __future__ import annotations

import os
import re
import sys

EVIDENCE_CAP = 80  # matches truncate_chars 80 in patterns.sh

# Reserved filenames, OKF §3.1. These have defined meaning at ANY level of the
# hierarchy and are NOT concept documents, so the concept-level rules (§4.1
# frontmatter, required `type`) do not apply to them. Exactly the spec's two —
# see the module docstring on why no repo-specific names join this tuple.
RESERVED = ("index.md", "log.md")

# Category slugs — kept as constants so the bash fallback reuses identical
# literals (byte-parity insurance), same discipline as the L_* labels below.
C_MISSING_TYPE = "okf-missing-type"
C_UNPARSEABLE = "okf-unparseable-frontmatter"
C_VERSION_DRIFT = "okf-version-drift"
C_RESERVED_STRUCTURE = "okf-reserved-file-structure"

# Evidence labels — ONE literal per situation, mirrored verbatim in patterns.sh.
L_NO_FRONTMATTER = "Concept has no frontmatter block"
L_UNTERMINATED = "Frontmatter block is not terminated"
L_BAD_LINE = "Frontmatter line is not parseable"
L_TYPE_ABSENT = "Concept frontmatter has no type key"
L_TYPE_EMPTY = "Concept type is present but empty"
L_DRIFT = "Bundle declares okf_version"
L_INDEX_FRONTMATTER = "index.md carries frontmatter"
L_LOG_DATE = "log.md date heading is not ISO 8601 YYYY-MM-DD"

# A frontmatter delimiter: `---` alone on its line (§4). Trailing whitespace is
# tolerated because editors add it invisibly and rejecting a document over it
# would be exactly the pedantry §11 forbids.
DELIM_RE = re.compile(r"^---[ \t]*$")

# A `key: value` line. The key shape is deliberately permissive — producers MAY
# add any keys (§4.1 Extensions) — but it must look like a key: no leading
# whitespace (that is a nested value, handled separately) and a colon.
KEY_RE = re.compile(r"^([^:#\s][^:]*):(.*)$")

# A nested/continuation line inside the block: indented content, a list item, a
# comment, or blank. We do not interpret these — the floor asks only that the
# block is parseable, and a full YAML model would be a much larger surface with
# a much larger chance of the two impls disagreeing.
NESTED_RE = re.compile(r"^([ \t]+.*|-[ \t].*|#.*|[ \t]*)$")

# §9: log.md date headings MUST be ISO 8601 YYYY-MM-DD. Any `##` heading in a
# log.md is treated as a date heading — that is what the section is for.
LOG_HEADING_RE = re.compile(r"^##[ \t]+(.*?)[ \t]*$")
ISO_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


def fail(message: str) -> int:
    """Print an actionable TOOL-side error and return the non-zero code.

    Distinct from every bundle-conformance path, which returns findings at
    exit 0. See the module docstring."""
    sys.stderr.write("ERROR: " + message + "\n")
    return 1


def bundle_root() -> str:
    """The configured bundle root, normalized for matching.

    Resolution order: $OKF_BUNDLE_ROOT -> $MEMORY_BUNDLE_ROOT -> `.claude/memory`.
    MEMORY_BUNDLE_ROOT is check-decomposition's existing convention (#700), so
    one setting moves every bundle-aware scanner together; OKF_BUNDLE_ROOT is
    the escape hatch for a repo whose OKF bundle is not its memory bundle.

    An EMPTY value means no bundle is configured: classification is off and
    nothing errors.

    Normalization strips a leading `./` and any trailing `/` so that every
    spelling of the same root — `.claude/memory`, `./.claude/memory`,
    `.claude/memory/` — decides alike. An unnormalized root would simply fail to
    match, the scan would emit nothing, and it would still exit 0: a silent
    fail-open (the #662 class). Mirrors _bundle_root() in
    check-decomposition/patterns.py.
    """
    root = os.environ.get("OKF_BUNDLE_ROOT")
    if root is None:
        root = os.environ.get("MEMORY_BUNDLE_ROOT", ".claude/memory")
    root = root.strip()
    while root.startswith("./"):
        root = root[2:]
    while root.endswith("/"):
        root = root[:-1]
    return root


def _thresholds_path() -> str:
    """thresholds.yml beside THIS file — resolved from the module location, not
    $PWD, so the scanner works from any working directory."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "thresholds.yml")


def read_pinned_version(path: str) -> str:
    """The pinned OKF version, or "" when it cannot be resolved.

    Resolution order: $OKF_PINNED_VERSION -> `okf.pinned_version` in
    thresholds.yml -> "" (which the caller turns into a loud non-zero exit).

    The parse is intentionally tiny and mirrors the bash twin exactly: find the
    top-level `okf:` key, then read `pinned_version:` from the indented block
    beneath it, stopping at the next top-level key. A full YAML parser would be
    a much bigger surface for the two impls to disagree across, and this file's
    shape is fixed.

    Quotes are stripped and an inline `# comment` is dropped, matching how the
    value is actually written in thresholds.yml.

    The top-level test is `line[0]` not being a space and not being `-`, matching
    the bash twin's globs. Deliberately NOT str.isalpha(), which is
    Unicode-aware where a bash glob is not — that exact divergence cost #686 a
    silent disagreement between the two runtimes reading one config.
    """
    env = os.environ.get("OKF_PINNED_VERSION", "").strip()
    if env:
        return env
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return ""
    in_okf = False
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # A column-0 line ends the `okf:` block. A top-level KEY may also open
        # it; a top-level LIST ITEM (`- ...`) only closes it, matching the bash
        # twin's three `case` arms exactly. Leaving `in_okf` untouched on the
        # list-item arm would let python keep reading an indented
        # `pinned_version:` that bash had already stepped out of — same file,
        # different pin, and on the config a consumer repo is invited to
        # override (thresholds.yml § "place a modified copy").
        if not line[0].isspace():
            in_okf = line.startswith("okf:")
            continue
        if not in_okf:
            continue
        stripped = line.strip()
        if not stripped.startswith("pinned_version:"):
            continue
        val = stripped[len("pinned_version:") :]
        # Drop an inline comment before unquoting, so `"0.2" # OKF_PINNED_VERSION`
        # yields `0.2` rather than the whole tail.
        hash_at = val.find("#")
        if hash_at >= 0:
            val = val[:hash_at]
        val = val.strip().strip("\"'").strip()
        return val
    return ""


def emit(path: str, line_no: int, category: str, evidence: str, certainty: str) -> None:
    """Write one TSV finding row.

    Evidence is capped at EVIDENCE_CAP CHARACTERS (not bytes) to match the bash
    twin's truncate_chars; a byte-wise cap can split a UTF-8 character and break
    parity on multibyte content (#17).

    Evidence carries a LABEL plus at most a fragment of the offending line. It
    must never carry a document's body: a memory bundle holds operator-specific
    working notes, and in a consumer repo material this repo has never seen
    (#664 Notes)."""
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence[:EVIDENCE_CAP], certainty))
        + "\n"
    )


def in_bundle(path: str, root: str) -> bool:
    """True when PATH lies under the configured bundle ROOT.

    LITERAL containment, deliberately not fnmatch. The root is operator
    configuration and may contain glob metacharacters (`[`, `*`, `?`); routing it
    through fnmatch would read those as syntax while the bash twin's QUOTED
    `case` pattern matches them literally — the two impls would then disagree
    about the same file, silently, at exit 0. Mirrors bundle_kind() in
    check-decomposition/patterns.py, which documents the same trap."""
    if not root:
        return False
    return path.startswith(root + "/") or ("/" + root + "/") in path


def is_bundle_root_file(path: str, root: str) -> bool:
    """True when PATH sits at the TOP level of the bundle, not in a subdirectory.

    §8 permits frontmatter in a bundle-ROOT index.md only, so this distinction
    decides whether an `okf_version` is legitimate or a structure finding."""
    if not root:
        return False
    if path.startswith(root + "/"):
        rest = path[len(root) + 1 :]
    else:
        marker = "/" + root + "/"
        at = path.find(marker)
        if at < 0:
            return False
        rest = path[at + len(marker) :]
    return "/" not in rest


def parse_frontmatter(lines: list[str]) -> tuple[dict[str, str], int, str, int]:
    """Parse a leading frontmatter block.

    Returns (keys, end_line, error, error_line) where `keys` maps key -> raw
    value string, `end_line` is the 1-based line of the closing delimiter (0 when
    there is no block), `error` is "" or one of the L_* labels, and `error_line`
    is the 1-based line the error refers to.

    The grammar is deliberately minimal — delimiters, `key: value`, and
    nested/list/comment/blank continuation lines. Anything structurally
    unrecognizable is reported as unparseable; nothing is interpreted beyond the
    keys themselves. Extra keys are collected without judgment: §4.1 says
    consumers MUST NOT reject documents with unrecognized fields.
    """
    keys: dict[str, str] = {}
    if not lines or not DELIM_RE.match(lines[0]):
        return ({}, 0, L_NO_FRONTMATTER, 1)
    for idx in range(1, len(lines)):
        line = lines[idx]
        if DELIM_RE.match(line):
            return (keys, idx + 1, "", 0)
        m = KEY_RE.match(line)
        if m:
            key = m.group(1).rstrip()
            # First occurrence wins, so a duplicated key cannot mask the first
            # value. Duplicates are not themselves a finding — §11 does not make
            # them one.
            if key not in keys:
                keys[key] = m.group(2).strip()
            continue
        if NESTED_RE.match(line):
            continue
        return (keys, 0, L_BAD_LINE, idx + 1)
    return (keys, 0, L_UNTERMINATED, 1)


def scan_concept(path: str, lines: list[str]) -> None:
    """Concept-level rules (§4.1, §11 items 1-2): parseable frontmatter with a
    non-empty `type`. Reserved files never reach here."""
    keys, _end, err, err_line = parse_frontmatter(lines)
    if err:
        emit(path, err_line, C_UNPARSEABLE, err, "HIGH")
        return
    if "type" not in keys:
        emit(path, 1, C_MISSING_TYPE, L_TYPE_ABSENT, "HIGH")
        return
    if not keys["type"].strip():
        emit(path, 1, C_MISSING_TYPE, L_TYPE_EMPTY, "HIGH")
    # An UNKNOWN type value is fully conformant (§4.1: "consumers MUST tolerate
    # unknown types gracefully"), as are any additional producer-defined keys.
    # Nothing more is checked — `type` is the entire floor.


def _okf_version_line(lines: list[str], end: int) -> int:
    """The 1-based line of the `okf_version` key inside the frontmatter block, so
    the finding points at the declaration rather than at line 1. Falls back to 1
    if it cannot be located."""
    limit = end if end > 0 else len(lines)
    for idx in range(1, limit):
        m = KEY_RE.match(lines[idx])
        if m and m.group(1).rstrip() == "okf_version":
            return idx + 1
    return 1


def scan_index(path: str, lines: list[str], root: str, pinned: str) -> None:
    """§8: an index.md carries NO frontmatter, with one exception — a
    bundle-ROOT index.md MAY carry `okf_version` (§12, the only place
    frontmatter is permitted in an index.md).

    An index.md with no frontmatter at all is the normal, conformant case and is
    silent. A MISSING index.md is likewise not a finding: §11 forbids rejecting
    a bundle for one, and a file that does not exist is never in the scan list."""
    if not lines or not DELIM_RE.match(lines[0]):
        return
    keys, end, err, err_line = parse_frontmatter(lines)
    if err:
        emit(path, err_line, C_UNPARSEABLE, err, "HIGH")
        return
    at_root = is_bundle_root_file(path, root)
    extra = [k for k in keys if k != "okf_version"]
    # A non-root index.md may carry no frontmatter at all; a root one may carry
    # okf_version and nothing else.
    if not at_root or extra:
        emit(path, 1, C_RESERVED_STRUCTURE, L_INDEX_FRONTMATTER, "MEDIUM")
    if at_root and "okf_version" in keys:
        declared = keys["okf_version"].strip().strip("\"'").strip()
        # An ABSENT okf_version is not a finding (§12: bundles MAY declare one).
        # A declared version that differs from the pin is LOW and still exit 0 —
        # §12 asks for best-effort consumption, not refusal.
        if declared and declared != pinned:
            emit(
                path,
                _okf_version_line(lines, end),
                C_VERSION_DRIFT,
                L_DRIFT + " " + declared + ", pinned " + pinned,
                "LOW",
            )


def scan_log(path: str, lines: list[str]) -> None:
    """§9: date headings MUST use ISO 8601 YYYY-MM-DD. The entries themselves are
    prose and the leading bold word (`**Update**`) is a convention, not a
    requirement — so nothing else in a log.md is checked."""
    fenced = False
    for idx, line in enumerate(lines, start=1):
        if line.startswith("```") or line.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = LOG_HEADING_RE.match(line)
        if not m:
            continue
        heading = m.group(1)
        if not ISO_DATE_RE.match(heading):
            emit(path, idx, C_RESERVED_STRUCTURE, L_LOG_DATE + ": " + heading, "MEDIUM")


def scan_file(path: str, lines: list[str], root: str, pinned: str) -> None:
    """Route one bundle file to the rules that apply to it."""
    base = path.rsplit("/", 1)[-1]
    if base == "index.md":
        scan_index(path, lines, root, pinned)
    elif base == "log.md":
        scan_log(path, lines)
    else:
        scan_concept(path, lines)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <file-list>\n")
        return 1

    # TOOL-side gate, resolved BEFORE any scanning: without a pin there is
    # nothing to compare a declared okf_version against, so proceeding would
    # emit a findings-free report of a bundle that was never fully checked.
    # Loud and non-zero, never a silent skip (#538/#571).
    pinned = read_pinned_version(_thresholds_path())
    if not pinned:
        return fail(
            "no OKF version pin — set OKF_PINNED_VERSION or provide "
            "`okf.pinned_version` in thresholds.yml. It is the single source "
            "of the pin; without it version drift cannot be judged."
        )
    if not re.match(r"^[0-9]+\.[0-9]+$", pinned):
        return fail(
            "OKF version pin is not a <major>.<minor> version: "
            + pinned
            + " (spec §12). A malformed pin would silently never match a "
            "declared version."
        )

    file_list = argv[1]
    try:
        with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
            paths = [ln.rstrip("\n") for ln in fh]
    except OSError:
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    root = bundle_root()
    for path in paths:
        if not path:
            continue
        # Only markdown inside the configured bundle is OKF content. A repo with
        # no bundle (or no configured root) simply produces nothing: "nothing to
        # check" is exit 0, not an error.
        if not path.endswith(".md") or not in_bundle(path, root):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines, root, pinned)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
