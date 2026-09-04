#!/usr/bin/env python3
"""loop-make-it-documented — Deterministic Pre-Scan (Python primary impl).

Detects documentation gaps: public functions without docstrings, exported
symbols without JSDoc/GoDoc, public classes without documentation.

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

EVIDENCE_CAP = 60  # printf '%.60s'

# Test/non-source files skipped wholesale (substring globs, matching the bash
# leading `case`).
SKIP_GLOBS = (
    "*test*",
    "*spec*",
    "*__pycache__*",
    "*.md",
    "*.yml",
    "*.yaml",
    "*.json",
    "*.toml",
    "*.lock",
)

PY_FUNC_RE = re.compile(r"^def [a-zA-Z][a-zA-Z0-9_]*\(")
PY_CLASS_RE = re.compile(r"^class [A-Z][a-zA-Z0-9_]*")
BLANK_RE = re.compile(r"^[ \t]*$")
PY_DOCSTRING_RE = re.compile(r"""^[ \t]*(""" '"""' r"""|''')""")

JS_DEF_RE = re.compile(
    r"^export\s+(async\s+)?function\s+\w+|^export\s+(default\s+)?class\s+\w+"
)
JSDOC_END_RE = re.compile(r"^\s*\*/")
GO_FUNC_RE = re.compile(r"^func [A-Z][a-zA-Z0-9]*\(")
SH_FUNC_RE = re.compile(r"^\w+\(\)")
COMMENT_RE = re.compile(r"^\s*#")


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, str(line_no), category, evidence, "HIGH")) + "\n")


def scan_python(path: str, lines: list[str]) -> None:
    # awk reads line by line; on a def/class it getlines forward to the first
    # non-blank and checks for a docstring opener. NOTE: like the awk, the forward
    # getline consumes lines, but awk's main loop then continues from where getline
    # left off. To stay byte-identical we replicate that consuming behavior.
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if PY_FUNC_RE.search(line):
            func_line = i + 1
            func_text = line
            # getline (advance past the def), then skip blanks.
            j = i + 1
            while j < n and BLANK_RE.match(lines[j]):
                j += 1
            nxt = lines[j] if j < n else ""
            if not PY_DOCSTRING_RE.match(nxt):
                emit(
                    path,
                    func_line,
                    "undocumented-public-function",
                    "No docstring: " + func_text[:EVIDENCE_CAP],
                )
            i = j + 1
            continue
        if PY_CLASS_RE.search(line):
            class_line = i + 1
            class_text = line
            j = i + 1
            while j < n and BLANK_RE.match(lines[j]):
                j += 1
            nxt = lines[j] if j < n else ""
            if not PY_DOCSTRING_RE.match(nxt):
                emit(
                    path,
                    class_line,
                    "undocumented-public-class",
                    "No docstring: " + class_text[:EVIDENCE_CAP],
                )
            i = j + 1
            continue
        i += 1


def scan_js(path: str, lines: list[str]) -> None:
    for idx, content in enumerate(lines, start=1):
        if not JS_DEF_RE.search(content):
            continue
        prev = idx - 1  # 1-based line before
        if prev > 0:
            prev_content = lines[prev - 1]
            if not JSDOC_END_RE.search(prev_content):
                ev = content[:EVIDENCE_CAP]
                category = "undocumented-export"
                if "class" in content:
                    category = "undocumented-public-class"
                emit(path, idx, category, "No JSDoc: " + ev)


def scan_go(path: str, lines: list[str]) -> None:
    # Go: an exported (capitalized) func whose preceding line is not a GoDoc
    # comment `// <FuncName>`. Matches the bash `grep -nE '^func [A-Z]...\('`
    # arm (fixed in #183 — it was dead under basic-regex `grep -n`).
    for idx, content in enumerate(lines, start=1):
        if not GO_FUNC_RE.search(content):
            continue
        m = re.search(r"^func ([A-Z][a-zA-Z0-9]*)", content)
        func_name = m.group(1) if m else ""
        prev = idx - 1
        if prev > 0:
            prev_content = lines[prev - 1]
            if not re.search(r"^// " + re.escape(func_name), prev_content):
                ev = content[:EVIDENCE_CAP]
                emit(
                    path,
                    idx,
                    "undocumented-export",
                    f"No GoDoc for {func_name}: " + ev,
                )


def scan_shell(path: str, lines: list[str]) -> None:
    for idx, content in enumerate(lines, start=1):
        if not SH_FUNC_RE.search(content):
            continue
        prev = idx - 1
        if prev > 0:
            prev_content = lines[prev - 1]
            if not COMMENT_RE.search(prev_content):
                ev = content[:EVIDENCE_CAP]
                emit(
                    path,
                    idx,
                    "undocumented-public-function",
                    "No comment before function: " + ev,
                )


def scan_file(path: str, lines: list[str]) -> None:
    base = path.rsplit("/", 1)[-1]
    ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
    if ext == "py":
        scan_python(path, lines)
    elif ext in ("ts", "js", "tsx", "jsx"):
        scan_js(path, lines)
    elif ext == "go":
        scan_go(path, lines)
    elif ext in ("sh", "bash"):
        scan_shell(path, lines)


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
