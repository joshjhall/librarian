#!/usr/bin/env python3
"""loop-make-it-tested — Deterministic Pre-Scan (Python primary implementation).

Detects test coverage gaps: public functions without test files, test files
without assertions, source modules without test counterparts.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Filesystem-dependent: probes for sibling test files and greps them, exactly like
patterns.sh, so the two impls agree on the same working tree.
"""

from __future__ import annotations

import glob as _glob
import os
import re
import sys
from fnmatch import fnmatch

# Test/non-source files skipped wholesale (substring globs) — leading bash `case`.
SKIP_GLOBS = (
    "*test*",
    "*spec*",
    "*__pycache__*",
    "*.md",
    "*.yml",
    "*.yaml",
    "*.json",
    "*.toml",
)

PY_PUBLIC_FUNC_RE = re.compile(r"^def [a-zA-Z][a-zA-Z0-9_]*\(")
GO_EXPORTED_FUNC_RE = re.compile(r"^func [A-Z][a-zA-Z0-9]*\(")


def _bash_read_content(line: str) -> str:
    if line.count(":") == 1 and line.endswith(":"):
        return line[:-1]
    return line


def emit(path: str, line_no: str, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, line_no, category, evidence, "HIGH")) + "\n")


def _word_in_file(fpath: str, word: str) -> bool:
    """`grep -q "\\b<word>\\b" fpath` — the word (as a \\b-bounded token) occurs."""
    pat = re.compile(r"\b" + re.escape(word) + r"\b")
    try:
        with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if pat.search(line):
                    return True
    except OSError:
        return False
    return False


def _word_in_any(globs: list[str], word: str) -> bool:
    """`grep -rql "\\b<word>\\b" <globs...>` — the word occurs in ANY matched file.
    Non-existent globs expand to nothing (grep would error to /dev/null → no match)."""
    pat = re.compile(r"\b" + re.escape(word) + r"\b")
    for g in globs:
        for fpath in _glob.glob(g):
            try:
                with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if pat.search(line):
                            return True
            except OSError:
                continue
    return False


def scan_file(path: str, lines: list[str]) -> None:
    base = path.rsplit("/", 1)[-1]
    dirname = path.rsplit("/", 1)[0] if "/" in path else "."
    name_no_ext = base.rsplit(".", 1)[0] if "." in base else base
    ext = base.rsplit(".", 1)[-1] if "." in base else ""

    # --- Category: missing-test-file ---
    has_test = False
    if ext == "py":
        for tp in (
            f"{dirname}/test_{name_no_ext}.py",
            f"{dirname}/tests/test_{name_no_ext}.py",
            f"{dirname}/../tests/test_{name_no_ext}.py",
            f"{dirname}/{name_no_ext}_test.py",
        ):
            if os.path.isfile(tp):
                has_test = True
                break
    elif ext in ("ts", "js", "tsx", "jsx"):
        for suffix in ("test", "spec"):
            for tp in (
                f"{dirname}/{name_no_ext}.{suffix}.{ext}",
                f"{dirname}/__tests__/{name_no_ext}.{suffix}.{ext}",
                f"{dirname}/../__tests__/{name_no_ext}.{suffix}.{ext}",
            ):
                if os.path.isfile(tp):
                    has_test = True
                    break
            if has_test:
                break
    elif ext == "go":
        if os.path.isfile(f"{dirname}/{name_no_ext}_test.go"):
            has_test = True
    elif ext == "rs":
        if any(re.search(r"#\[cfg\(test\)\]", ln) for ln in lines):
            has_test = True
        elif os.path.isdir(f"{dirname}/../tests"):
            has_test = True

    if not has_test:
        emit(path, "1", "missing-test-file", f"No test file found for {base}")

    # --- Category: untested-public-api ---
    if ext == "py":
        for idx, content in enumerate(lines, start=1):
            if not PY_PUBLIC_FUNC_RE.search(content):
                continue
            m = re.search(r"^def ([a-zA-Z][a-zA-Z0-9_]*)", content)
            func_name = m.group(1) if m else ""
            if not _word_in_any(
                [f"{dirname}/test_*.py", f"{dirname}/tests/test_*.py"], func_name
            ):
                ev = _bash_read_content(content)[:60]
                emit(
                    path,
                    str(idx),
                    "untested-public-api",
                    f"No tests reference {func_name}: " + ev,
                )
    elif ext == "go":
        for idx, content in enumerate(lines, start=1):
            if not GO_EXPORTED_FUNC_RE.search(content):
                continue
            m = re.search(r"^func ([A-Z][a-zA-Z0-9]*)", content)
            func_name = m.group(1) if m else ""
            test_file = f"{dirname}/{name_no_ext}_test.go"
            if os.path.isfile(test_file) and not _word_in_file(test_file, func_name):
                ev = _bash_read_content(content)[:60]
                emit(
                    path,
                    str(idx),
                    "untested-public-api",
                    f"No tests reference {func_name}: " + ev,
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
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
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
