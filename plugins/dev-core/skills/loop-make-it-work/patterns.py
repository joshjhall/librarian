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

# FIDELITY NOTE: the bash empty-body ERE for JS/Go uses `\{[\s]*\}`. In POSIX ERE
# `[\s]` is a bracket class of the LITERAL characters backslash and 's' — NOT a
# whitespace shorthand. So bash matches `{`, then zero+ of {backslash, s}, then
# `}` — e.g. `{}`, `{s}`, `{\}`, `{ss}` — but NOT `{ }` (a real space). These
# regexes replicate that exact class so parity holds; a follow-up may switch to
# real whitespace (`\s*`).
JS_EMPTY_BODY_RE = re.compile(r"(function\s+\w+|=>\s*)\{[\\s]*\}")
GO_EMPTY_BODY_RE = re.compile(r"^func\s+.*\{[\\s]*\}")

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



def scan_file(path: str, lines: list[str]) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    base = path.rsplit("/", 1)[-1]

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
            # FIDELITY NOTE: the bash Python empty-body arm is DEAD. It computes
            # the next non-blank line with `grep -m1 -nE '\S'` — the `-n` prepends
            # a "<lineno>:" prefix, so the following `grep -qE '^\s*(pass|...)'`
            # never matches (the string starts with a digit). So a Python
            # `def f(): pass` is never flagged empty-body by bash. Replicated here
            # (this arm emits nothing). The JS/Go arms below do NOT have this bug
            # and are ported working. A follow-up may drop the stray `-n`.
            pass
        elif ext in ("ts", "js", "tsx", "jsx"):
            if JS_EMPTY_BODY_RE.search(content):
                emit(
                    path,
                    str(idx),
                    "empty-body",
                    "Empty function body: " + _bash_read_content(content)[:EVIDENCE_CAP],
                )
        elif ext == "go":
            if GO_EMPTY_BODY_RE.search(content):
                emit(
                    path,
                    str(idx),
                    "empty-body",
                    "Empty function body: " + _bash_read_content(content)[:EVIDENCE_CAP],
                )

    # --- Category: no-assertions (whole-file, test files only) ---
    # Path-glob dispatch mirrors the bash `case "$file"` arms (matched on the
    # full path, not just basename — `*test*.py` etc. are unanchored globs).
    if fnmatch(path, "*test*.py") or fnmatch(path, "*_spec.py"):
        if not any(PY_ASSERT_RE.search(ln) for ln in lines):
            emit(path, "1", "no-assertions", "Test file contains no assertion statements")
    elif (
        fnmatch(path, "*.test.ts")
        or fnmatch(path, "*.test.js")
        or fnmatch(path, "*.spec.ts")
        or fnmatch(path, "*.spec.js")
        or fnmatch(path, "*.test.tsx")
        or fnmatch(path, "*.test.jsx")
    ):
        if not any(JS_ASSERT_RE.search(ln) for ln in lines):
            emit(path, "1", "no-assertions", "Test file contains no assertion statements")
    elif fnmatch(path, "*_test.go"):
        if not any(GO_ASSERT_RE.search(ln) for ln in lines):
            emit(path, "1", "no-assertions", "Test file contains no assertion statements")


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
