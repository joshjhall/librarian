#!/usr/bin/env python3
"""loop-make-it-secure — Deterministic Pre-Scan (Python primary implementation).

Detects security issues: hardcoded secrets, string interpolation in queries,
dangerous function usage, and denylist validation patterns.

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
from fnmatch import fnmatch

CERTAINTY = "HIGH"
EVIDENCE_CAP = 80  # matches printf '%.80s' in patterns.sh

# Test/fixture files skipped wholesale — security patterns in tests are often
# intentional. Mirrors the leading `case "$file"` skip arm (substring globs).
SKIP_GLOBS = ("*test*", "*spec*", "*fixture*", "*mock*", "*fake*")

# FIDELITY NOTE (see #168 for the same bug in check-security): the bash regexes
# below write the single-quote delimiter as `\x27` inside a POSIX bracket
# expression. GNU grep does NOT expand `\x27` there — it adds the literal
# characters \, x, 2, 7 to the class. So the real quote-delimiter class is
# [ " \ x 2 7 ] (NOT [ " ' ]): a single-quoted secret value or f'...' string is
# missed. This port REPLICATES that class exactly for byte-parity; the fix (use a
# real ') is tracked as a follow-up, not this port. In the Python patterns below,
# `["\\x27]` is that same buggy class (`\\` = literal backslash; x,2,7 literal).
SECRET_KEYS = (
    r"(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token"
    r"|secret[_-]?key|password|passwd|private[_-]?key)"
)
SECRET_RE = re.compile(
    SECRET_KEYS + r"""\s*[=:]\s*["\\x27][A-Za-z0-9+/=_-]{16,}""", re.IGNORECASE
)
AWS_RE = re.compile(r"AKIA[0-9A-Z]{16}")

# string-interpolation-query, per language.
PY_SQL_RE = re.compile(r"""(execute|cursor)\s*\(\s*f["\\x27]""")
JS_SQL_RE = re.compile(r"(query|execute)\s*\(\s*`[^`]*(SELECT|INSERT|UPDATE|DELETE)")
GO_SQL_RE = re.compile(r"(Exec|Query|QueryRow)\s*\(\s*fmt\.Sprintf")

# dangerous-function (all languages).
DANGER_FN_RE = re.compile(
    r"\b(subprocess\.call\s*\(.*shell\s*=\s*True|child_process\.exec\s*\()"
)
# Unsafe deserialization. FIDELITY NOTE: the bash regex is
# `\b(yaml\.load\s*\([^)]*\)(?!.*Loader)|marshal\.loads?\s*\()` run under
# `grep -E` (POSIX ERE). ERE has no PCRE negative-lookahead: GNU grep parses the
# `(?!.*Loader)` as a malformed group and the ENTIRE yaml.load alternative never
# matches any input (verified: grep -E returns no match even for a line ending in
# the literal "(?!.*Loader)"). So in practice bash flags marshal.loads ONLY, and
# yaml.load detection is dead. This port replicates that observed behavior — only
# the marshal.loads branch — so parity holds. Restoring real yaml.load-without-
# Loader detection is a tracked follow-up, not this port.
UNSAFE_DESERIALIZE_RE = re.compile(r"\bmarshal\.loads?\s*\(")

# denylist-validation (all languages).
DENYLIST_RE = re.compile(
    r"(blacklist|blocklist|denylist|banned|forbidden)\s*=\s*\[", re.IGNORECASE
)


def emit(path: str, line_no: int, category: str, label: str, content: str) -> None:
    """Write one TSV finding row: '<label>: <first 80 chars of the line>'."""
    evidence = label + ": " + content[:EVIDENCE_CAP]
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


def scan_file(path: str, lines: list[str]) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    for idx, line in enumerate(lines, start=1):
        # --- Category: hardcoded-secret ---
        if SECRET_RE.search(line):
            emit(path, idx, "hardcoded-secret", "Possible hardcoded secret", line)
        if AWS_RE.search(line):
            emit(path, idx, "hardcoded-secret", "AWS access key pattern", line)

        # --- Category: string-interpolation-query (per-language) ---
        if ext == "py":
            if PY_SQL_RE.search(line):
                emit(
                    path,
                    idx,
                    "string-interpolation-query",
                    "SQL with string interpolation",
                    line,
                )
        elif ext in ("ts", "js", "tsx", "jsx"):
            if JS_SQL_RE.search(line):
                emit(
                    path,
                    idx,
                    "string-interpolation-query",
                    "SQL with string interpolation",
                    line,
                )
        elif ext == "go":
            if GO_SQL_RE.search(line):
                emit(
                    path,
                    idx,
                    "string-interpolation-query",
                    "SQL with string interpolation",
                    line,
                )

        # --- Category: dangerous-function (all languages) ---
        if DANGER_FN_RE.search(line):
            emit(path, idx, "dangerous-function", "Dangerous function usage", line)
        if UNSAFE_DESERIALIZE_RE.search(line):
            emit(path, idx, "dangerous-function", "Unsafe deserialization", line)

        # --- Category: denylist-validation (all languages) ---
        if DENYLIST_RE.search(line):
            emit(
                path,
                idx,
                "denylist-validation",
                "Denylist pattern (prefer allowlist)",
                line,
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
        if not path:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
