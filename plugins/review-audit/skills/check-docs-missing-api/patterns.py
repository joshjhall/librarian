#!/usr/bin/env python3
"""check-docs-missing-api — Deterministic Pre-Scan (Python primary implementation).

Detects exported/public functions without documentation across languages. Uses
language-specific patterns to find definitions missing a preceding
docstring/comment block (and, for Python, an immediately-following docstring).

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found
"""

from __future__ import annotations

import os
import re
import sys

CATEGORY = "undocumented-public-api"
CERTAINTY = "HIGH"
EVIDENCE_CAP = 80  # matches printf '%.80s' in patterns.sh


def emit(path: str, line_no: int, label: str, content: str) -> None:
    """Write one TSV finding row: '<lang>: <first 80 chars of the def line>'."""
    evidence = label + ": " + content[:EVIDENCE_CAP]
    sys.stdout.write(
        "\t".join((path, str(line_no), CATEGORY, evidence, CERTAINTY)) + "\n"
    )


def block_matches(lines: list[str], start_1: int, end_1: int, pattern: str) -> bool:
    """Mirror `sed -n 'START,ENDp' | grep -qE PATTERN` — does any line in the
    inclusive 1-indexed range [start_1, end_1] match PATTERN? grep applies the
    regex per line, so `^`/`$` anchor to each line's own bounds."""
    if end_1 < start_1:
        # pragma: no cover — unreachable: the sole caller check_prev_lines always
        # passes end_1 = target-1, start_1 = target-3 (a fixed +2 span), so
        # end_1 < start_1 never holds. Kept as a defensive guard mirroring bash.
        return False  # pragma: no cover
    start_1 = max(1, start_1)
    for ln in lines[start_1 - 1 : end_1]:
        if re.search(pattern, ln):
            return True
    return False


def check_prev_lines(lines: list[str], target_1: int, pattern: str) -> bool:
    """`check_prev_lines` from patterns.sh: PATTERN present in the up-to-3 lines
    immediately before TARGET_1 (1-indexed), clamped to line 1."""
    return block_matches(lines, target_1 - 3, target_1 - 1, pattern)


def scan_file(path: str) -> None:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:  # pragma: no cover — main() already opened this path in its
        # own try/except before calling scan_file, so a second open failure here
        # is only reachable via a TOCTOU race; the covered arm is main's except.
        return

    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    def defs(pattern: str):
        """Yield (line_no, content) for lines matching a def/export pattern —
        the per-language `grep -nE PATTERN` outer loop."""
        for idx, line in enumerate(lines, start=1):
            if re.search(pattern, line):
                yield idx, line

    if ext == "py":
        for line_no, content in defs(r"^(def |class )[A-Za-z_]"):
            # Skip private definitions — anchor on the NAME (the token after
            # def/class), NOT a whole-line substring: a genuinely-public def
            # whose trailing comment merely mentions `def _x` must still be
            # flagged (#348). The `defs` pattern now admits a leading underscore
            # so the private def reaches this name-anchored skip.
            m = re.match(r"^(?:def|class)\s+(\w+)", content)
            if m and m.group(1).startswith("_"):
                continue
            # Documented if a docstring precedes it OR the body opens with one.
            if check_prev_lines(lines, line_no, '"""'):
                continue
            next_two = lines[line_no : line_no + 2]  # 1-indexed line_no+1..+2
            if any(re.search(r'^\s+"""', ln) for ln in next_two):
                continue
            emit(path, line_no, "Python", content)

    elif ext in ("js", "ts", "jsx", "tsx"):
        for line_no, content in defs(
            r"^export (function|class|const|type|interface|enum) "
        ):
            if not check_prev_lines(lines, line_no, r"/\*\*"):
                emit(path, line_no, "JS/TS", content)

    elif ext == "go":
        # Go convention: a doc comment line immediately above naming the func.
        if path.endswith("_test.go"):
            return
        for line_no, content in defs(r"^func [A-Z]"):
            m = re.search(r"func ([A-Z][A-Za-z0-9]*)", content)
            if not m:  # pragma: no cover — unreachable: the outer defs() filter
                # `^func [A-Z]` guarantees a "func <Upper>" prefix, so this inner
                # re.search always matches. Kept as a defensive guard.
                continue
            func_name = m.group(1)
            prev_line = lines[line_no - 2] if line_no - 1 >= 1 else ""
            if ("// " + func_name) not in prev_line:
                emit(path, line_no, "Go", content)

    elif ext == "rs":
        for line_no, content in defs(r"^pub (fn|struct|enum|trait|type) "):
            if not check_prev_lines(lines, line_no, r"^\s*///"):
                emit(path, line_no, "Rust", content)

    elif ext == "swift":
        # Swift public API (#839). Two access levels are public surface: `public`
        # and `open` (open additionally permits subclassing/overriding outside
        # the module). `internal` is the default and is NOT public, so an
        # unmarked declaration is correctly not matched.
        #
        # The declarator alternation includes `actor` (Swift 5.5) and both
        # binding keywords: a `public let`/`public var` IS public API surface in
        # a way a private field is not.
        #
        # Modifiers may appear BETWEEN the access level and the declarator
        # (`public final class`, `public static func`), so the pattern admits a
        # repeated modifier group. This mirrors loc_engine.py's Swift UNIT_RE,
        # which records that Swift imposes no canonical modifier order.
        for line_no, content in defs(
            r"^\s*(public|open)\s+"
            r"(final\s+|static\s+|class\s+|mutating\s+|override\s+|indirect\s+)*"
            r"(func|class|struct|enum|protocol|actor|typealias|var|let)\s"
        ):
            # `///` is the Swift doc-comment marker; `/**` is the block form.
            # NOTE `///` is matched here EXPLICITLY rather than being left to
            # work by accident of starting with `//` — a plain `//` comment is
            # NOT documentation and must not suppress the finding (#839 AC3).
            if not check_prev_lines(lines, line_no, r"^\s*(///|/\*\*)"):
                emit(path, line_no, "Swift", content)

    elif ext in ("sh", "bash"):
        for line_no, content in defs(
            r"^[a-zA-Z_][a-zA-Z0-9_]*\(\)|^function [a-zA-Z_]"
        ):
            # Skip private functions — anchor on the NAME, not a whole-line
            # substring (#348): the `_helper()` and `function _helper` forms are
            # private, but a public function whose comment mentions `function _x`
            # must still be flagged.
            m = re.match(r"^(?:function\s+)?(\w+)", content)
            if m and m.group(1).startswith("_"):
                continue
            if not check_prev_lines(lines, line_no, r"^\s*#"):
                emit(path, line_no, "Shell", content)

    elif ext == "rb":
        for line_no, content in defs(r"^\s*def [a-z]"):
            if not check_prev_lines(lines, line_no, r"^\s*#"):
                emit(path, line_no, "Ruby", content)

    elif ext in ("java", "kt"):
        for line_no, content in defs(
            r"^\s*public .*(void|int|String|boolean|List|Map|Optional|fun )"
        ):
            if not check_prev_lines(lines, line_no, r"/\*\*"):
                emit(path, line_no, "Java/Kotlin", content)


# --- input-shape guard (#816) -----------------------------------------------
# Mirrors assert_file_list_shape() in the bash fallback. Same two checks, same
# severities, same messages -- the two runtimes must agree on WHEN they fail or
# their exit codes diverge under tests/validate-python-ports.sh parity. Both
# write to stderr ONLY, so the stdout TSV that parity compares is untouched.
#
# Why the two differ in severity: a diff is an unambiguous wrong shape and its
# silent-zero scan is exactly the #816 defect, so it is fatal. A list whose
# paths do not resolve may be legitimate (a diff that only deletes files), and
# an EMPTY list must stay silent -- tests/validate-prescans.sh pins that for
# every pre-scan -- so that one warns and lets the scan proceed.
def _strip_control(text: str) -> str:
    """TEXT with control characters removed (tab kept).

    The offending line is caller-supplied and may come from an untrusted diff.
    Raw ESC/BEL echoed to the operator's terminal can move the cursor, hide
    following output, or drive an OSC title-bar sequence, so it is stripped
    before it is reflected. Mirrors the `tr -d` in the bash fallback.
    """
    return "".join(c for c in text if c == "\t" or (c.isprintable() and c != "\x7f"))


_DIFF_PREFIXES = ("diff --git ", "--- ", "+++ ", "@@ ")


def assert_file_list_shape(paths: list[str], list_path: str, tool: str) -> int:
    """Return 1 when PATHS is a diff (caller must exit), else 0. Warns on stderr
    when nothing in a non-empty list resolves."""
    total = 0
    resolved = 0
    for line in paths:
        if not line:
            continue
        total += 1
        if line.startswith(_DIFF_PREFIXES):
            sys.stderr.write(
                "Error: "
                + tool
                + ": input looks like a DIFF, not a file list: "
                + list_path
                + "\n  Offending line: "
                + _strip_control(line)
                + "\n  Expected one path per line -- did you mean"
                + " 'git diff --name-only'?"
                + "\n  Refusing to scan: a diff matches no path, so this"
                + " would emit nothing and exit 0, which reads as a clean"
                + " scan.\n"
            )
            return 1
        if os.path.exists(line):
            resolved += 1

    if total > 0 and resolved == 0:
        sys.stderr.write(
            "Warning: "
            + tool
            + ": no path listed in "
            + list_path
            + " exists ("
            + str(total)
            + " non-empty lines); scanning nothing."
            + "\n  A stale list or a wrong working directory yields an empty"
            + " scan that reads as clean. Findings below (if any) are from a"
            + " partial view.\n"
        )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <file-list>\n")
        return 1

    file_list = argv[1]
    try:
        with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
            paths = [ln.rstrip("\n") for ln in fh]
    except OSError:
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    if assert_file_list_shape(paths, file_list, os.path.basename(__file__)):
        return 1

    for path in paths:
        if not path:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace"):
                pass
        except OSError:
            continue
        scan_file(path)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
