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

import re
import sys

CATEGORY = "undocumented-public-api"
CERTAINTY = "HIGH"
EVIDENCE_CAP = 80  # matches printf '%.80s' in patterns.sh


def _bash_read_content(line: str) -> str:
    """Reproduce the `grep -n | while IFS=: read -r line_num content` splitting
    the bash impl feeds into its evidence, so this port is byte-identical.

    `grep -n` prefixes `<lineno>:`; the loop reads with `IFS=:` into two vars, so
    `content` is the remainder after the first colon with the last (empty) field
    dropped when the line ends in a lone extra colon. Concretely, the only
    observable effect on real def/decl lines is: a single trailing colon is
    stripped IFF the line contains exactly one colon and ends with it (e.g.
    Python `def f():` → `def f()`, `class C:` → `class C`). Lines with an
    interior colon (`def f(a: int):`) or none are returned unchanged — matching
    `IFS=: read` exactly (verified against bash across a corpus)."""
    if line.count(":") == 1 and line.endswith(":"):
        return line[:-1]
    return line


def emit(path: str, line_no: int, label: str, content: str) -> None:
    """Write one TSV finding row: '<lang>: <first 80 chars of the def line>'."""
    evidence = label + ": " + _bash_read_content(content)[:EVIDENCE_CAP]
    sys.stdout.write(
        "\t".join((path, str(line_no), CATEGORY, evidence, CERTAINTY)) + "\n"
    )


def block_matches(lines: list[str], start_1: int, end_1: int, pattern: str) -> bool:
    """Mirror `sed -n 'START,ENDp' | grep -qE PATTERN` — does any line in the
    inclusive 1-indexed range [start_1, end_1] match PATTERN? grep applies the
    regex per line, so `^`/`$` anchor to each line's own bounds."""
    if end_1 < start_1:
        return False
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
    except OSError:
        return

    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    def defs(pattern: str):
        """Yield (line_no, content) for lines matching a def/export pattern —
        the per-language `grep -nE PATTERN` outer loop."""
        for idx, line in enumerate(lines, start=1):
            if re.search(pattern, line):
                yield idx, line

    if ext == "py":
        for line_no, content in defs(r"^(def |class )[A-Za-z]"):
            # Skip private definitions (leading underscore).
            if "def _" in content or "class _" in content:
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
            if not m:
                continue
            func_name = m.group(1)
            prev_line = lines[line_no - 2] if line_no - 1 >= 1 else ""
            if ("// " + func_name) not in prev_line:
                emit(path, line_no, "Go", content)

    elif ext == "rs":
        for line_no, content in defs(r"^pub (fn|struct|enum|trait|type) "):
            if not check_prev_lines(lines, line_no, r"^\s*///"):
                emit(path, line_no, "Rust", content)

    elif ext in ("sh", "bash"):
        for line_no, content in defs(
            r"^[a-zA-Z_][a-zA-Z0-9_]*\(\)|^function [a-zA-Z_]"
        ):
            # Skip private functions (leading underscore, either form).
            if content.startswith("_") or "function _" in content:
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
