#!/usr/bin/env python3
"""loop-make-it-work — Deterministic Pre-Scan (Python primary implementation).

Detects incomplete implementation blockers: stubs, placeholders, empty function
bodies, and test files without assertions.

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
from fnmatch import fnmatch

EVIDENCE_CAP = 80

STUB_RE = re.compile(
    r"\b(TODO|FIXME|STUB|PLACEHOLDER)\b|NotImplementedError"
    r"|raise NotImplementedError|unimplemented!\(\)|todo!\(\)"
    r'|panic\("not implemented"\)',
    re.IGNORECASE,
)

# Empty-brace body: `{` then only whitespace then `}`. The bash ERE now uses
# `[[:space:]]*` (fixed in #183 — the old `[\s]*` matched literal backslash/'s',
# not whitespace, so `{ }` slipped through).
JS_EMPTY_BODY_RE = re.compile(r"(function\s+\w+|=>\s*)\{\s*\}")
GO_EMPTY_BODY_RE = re.compile(r"^func\s+.*\{\s*\}")

# Python empty-body: a `def` whose next non-blank line is only `pass` or `...`.
PY_DEF_RE = re.compile(r"^\s*def\s+\w+")
PY_EMPTY_BODY_RE = re.compile(r"^\s*(pass|\.\.\.)\s*$")

PY_ASSERT_RE = re.compile(
    r"\b(assert|assertEqual|assertTrue|assertFalse|assertRaises|assertIn|pytest\.raises)\b"
)
JS_ASSERT_RE = re.compile(r"\b(expect|assert|should)\b")
GO_ASSERT_RE = re.compile(r"\b(t\.(Error|Fatal|Log|Run|Helper)|assert\.|require\.)\b")


def _bash_read_content(line: str) -> str:
    if line.count(":") == 1 and line.endswith(":"):
        return line[:-1]
    return line


def emit(path: str, line_no: str, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, line_no, category, evidence, "HIGH")) + "\n")


def _first_nonblank_after(lines: list[str], idx0: int) -> str:
    """First non-blank line at or after 0-based index idx0 (matches the bash
    `sed -n 'N,$p' | grep -m1 -E '\\S' | head -1`), or '' at EOF."""
    for ln in lines[idx0:]:
        if re.search(r"\S", ln):
            return ln
    return ""


def scan_file(path: str, lines: list[str]) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    for idx, content in enumerate(lines, start=1):
        # --- Category: stub-detected ---
        if STUB_RE.search(content):
            emit(
                path,
                str(idx),
                "stub-detected",
                "Stub/placeholder: " + _bash_read_content(content)[:EVIDENCE_CAP],
            )

        # --- Category: empty-body (per language) ---
        if ext == "py":
            # A `def` whose next non-blank line is only `pass` or `...`. Matches
            # the bash arm fixed in #183 (its stray `grep -n` had disabled this).
            if PY_DEF_RE.search(content):
                nxt = _first_nonblank_after(lines, idx)
                if PY_EMPTY_BODY_RE.search(nxt):
                    emit(
                        path,
                        str(idx),
                        "empty-body",
                        "Empty function body: "
                        + _bash_read_content(content)[:EVIDENCE_CAP],
                    )
        elif ext in ("ts", "js", "tsx", "jsx"):
            if JS_EMPTY_BODY_RE.search(content):
                emit(
                    path,
                    str(idx),
                    "empty-body",
                    "Empty function body: "
                    + _bash_read_content(content)[:EVIDENCE_CAP],
                )
        elif ext == "go":
            if GO_EMPTY_BODY_RE.search(content):
                emit(
                    path,
                    str(idx),
                    "empty-body",
                    "Empty function body: "
                    + _bash_read_content(content)[:EVIDENCE_CAP],
                )

    # --- Category: no-assertions (whole-file, test files only) ---
    # Path-glob dispatch mirrors the bash `case "$file"` arms (matched on the
    # full path, not just basename — `*test*.py` etc. are unanchored globs).
    if fnmatch(path, "*test*.py") or fnmatch(path, "*_spec.py"):
        if not any(PY_ASSERT_RE.search(ln) for ln in lines):
            emit(
                path, "1", "no-assertions", "Test file contains no assertion statements"
            )
    elif (
        fnmatch(path, "*.test.ts")
        or fnmatch(path, "*.test.js")
        or fnmatch(path, "*.spec.ts")
        or fnmatch(path, "*.spec.js")
        or fnmatch(path, "*.test.tsx")
        or fnmatch(path, "*.test.jsx")
    ):
        if not any(JS_ASSERT_RE.search(ln) for ln in lines):
            emit(
                path, "1", "no-assertions", "Test file contains no assertion statements"
            )
    elif fnmatch(path, "*_test.go"):
        if not any(GO_ASSERT_RE.search(ln) for ln in lines):
            emit(
                path, "1", "no-assertions", "Test file contains no assertion statements"
            )


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
        if not path or not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
