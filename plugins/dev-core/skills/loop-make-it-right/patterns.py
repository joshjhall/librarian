#!/usr/bin/env python3
"""loop-make-it-right — Deterministic Pre-Scan (Python primary implementation).

Detects structural quality issues: long functions, deep nesting, and
single-character variable names outside loop counters.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Thresholds are env-overridable (LOOP_MAX_FUNCTION_LINES, LOOP_MAX_NESTING_DEPTH),
matching the bash impl so the orchestrator's thresholds.yml values apply either
way.
"""

from __future__ import annotations

import os
import re
import sys

CERTAINTY = "HIGH"
EVIDENCE_CAP = 60  # long-function/nesting/name evidence uses printf '%.60s'

BRACE_EXTS = ("ts", "js", "tsx", "jsx", "go", "rs")

# Function-definition patterns.
PY_DEF_RE = re.compile(r"^\s*def \w+")
BRACE_DEF_RE = re.compile(
    r"^\s*(export\s+)?(async\s+)?function\s+\w+|^func\s+|^(pub\s+)?fn\s+"
)
# single-char-name (Python only): a leading-indented single letter assignment.
PY_SINGLE_ASSIGN_RE = re.compile(r"^\s+[a-zA-Z]\s*=")
PY_SINGLE_SKIP_RE = re.compile(r"^\s*(for|with)\s+[a-zA-Z]\s+in\b|_\s*=")
PY_VARNAME_RE = re.compile(r"^\s*([a-zA-Z])\s*=")

# Conventional single-char names never flagged (loop counters etc.).
SKIP_VARNAMES = {"i", "j", "k", "n", "x", "y", "_", "e", "f"}


def _int_env(name: str, default: int) -> int:
    """Read an integer env override, falling back to default on unset/empty/bad —
    mirrors bash `${VAR:-default}` followed by integer use."""
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


def _leading_ws_len(line: str) -> int:
    """Number of leading whitespace chars (awk RLENGTH of /^[[:space:]]+/)."""
    m = re.match(r"[ \t]+", line)
    return m.end() if m else 0


def scan_long_functions(path: str, lines: list[str], ext: str, max_lines: int) -> None:
    total = len(lines)
    if ext == "py":
        # Python: from `def`, count to the next line at same-or-lower indent.
        for idx, content in enumerate(lines, start=1):
            if not PY_DEF_RE.search(content):
                continue
            # indent = char count up to the first non-space, minus that char.
            # bash: printf %s content | sed 's/[^ ].*//' | wc -c  → leading
            # spaces + the trailing newline wc counts = (num spaces) + 1.
            stripped = re.sub(r"[^ ].*", "", content)
            indent = len(stripped) + 1  # wc -c counts the newline
            # end_line = first following line matching ^.\{0,indent\}[^ ]
            end_off = None
            pat = re.compile(r"^.{0," + str(indent) + r"}[^ ]")
            for off, ln in enumerate(lines[idx:], start=1):
                if pat.search(ln):
                    end_off = off
                    break
            func_lines = end_off if end_off is not None else (total - idx)
            if func_lines > max_lines:
                ev = content[:EVIDENCE_CAP]
                emit(
                    path,
                    idx,
                    "long-function",
                    f"Function {func_lines} lines (max {max_lines}): {ev}",
                )
    elif ext in BRACE_EXTS:
        # Brace languages: count from a definition to the next definition.
        for idx, content in enumerate(lines, start=1):
            if not BRACE_DEF_RE.search(content):
                continue
            next_off = None
            for off, ln in enumerate(lines[idx:], start=1):
                if BRACE_DEF_RE.search(ln):
                    next_off = off
                    break
            func_lines = next_off if next_off is not None else (total - idx)
            if func_lines > max_lines:
                ev = content[:EVIDENCE_CAP]
                emit(
                    path,
                    idx,
                    "long-function",
                    f"Function {func_lines} lines (max {max_lines}): {ev}",
                )


def scan_deep_nesting(path: str, lines: list[str], ext: str, max_depth: int) -> None:
    # Python: 4-space indent unit; brace langs: 2-space unit. Only lines that
    # begin with whitespace THEN a non-space are considered (awk guard).
    if ext == "py":
        unit = 4
    elif ext in BRACE_EXTS:
        unit = 2
    else:
        return
    for idx, line in enumerate(lines, start=1):
        if not re.match(r"[ \t]+[^ \t]", line):
            continue
        depth = _leading_ws_len(line) // unit
        if depth > max_depth:
            ev = line[:EVIDENCE_CAP]
            emit(
                path,
                idx,
                "deep-nesting",
                f"Nesting depth {depth} (max {max_depth}): {ev}",
            )


def scan_single_char_names(path: str, lines: list[str], ext: str) -> None:
    if ext != "py":
        return
    for idx, content in enumerate(lines, start=1):
        if not PY_SINGLE_ASSIGN_RE.search(content):
            continue
        if PY_SINGLE_SKIP_RE.search(content):
            continue
        m = PY_VARNAME_RE.search(content)
        if not m:  # pragma: no cover - unreachable: PY_SINGLE_ASSIGN_RE above
            # (`^\s+[a-zA-Z]\s*=`) guarantees PY_VARNAME_RE (`^\s*([a-zA-Z])\s*=`)
            # matches, so `not m` never occurs; defensive only (bash sed would
            # leave content unchanged, yielding a varname that matches no skip).
            continue
        varname = m.group(1)
        if varname in SKIP_VARNAMES:
            continue
        ev = content[:EVIDENCE_CAP]
        emit(
            path,
            idx,
            "single-char-name",
            f"Single-character variable '{varname}': {ev}",
        )


def scan_file(path: str, lines: list[str], max_lines: int, max_depth: int) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    scan_long_functions(path, lines, ext, max_lines)
    scan_deep_nesting(path, lines, ext, max_depth)
    scan_single_char_names(path, lines, ext)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <file-list>\n")
        return 1

    max_lines = _int_env("LOOP_MAX_FUNCTION_LINES", 50)
    max_depth = _int_env("LOOP_MAX_NESTING_DEPTH", 4)

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
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines, max_lines, max_depth)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
