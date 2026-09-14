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

import os
import re
import sys
from fnmatch import fnmatch

CERTAINTY = "HIGH"
EVIDENCE_CAP = 80  # matches printf '%.80s' in patterns.sh

# Test/fixture files skipped wholesale — security patterns in tests are often
# intentional. Mirrors the leading `case "$file"` skip arm (substring globs).
SKIP_GLOBS = ("*test*", "*spec*", "*fixture*", "*mock*", "*fake*")

# The quote-delimiter class is ["'] — a double or single quote (matches the bash
# regex fixed in #183; the earlier ["\x27] never matched single-quoted values).
SECRET_KEYS = (
    r"(api[_-]?key|api[_-]?secret|auth[_-]?token|access[_-]?token"
    r"|secret[_-]?key|password|passwd|private[_-]?key)"
)
SECRET_RE = re.compile(
    SECRET_KEYS + r"""\s*[=:]\s*["'][A-Za-z0-9+/=_-]{16,}""", re.IGNORECASE
)
AWS_RE = re.compile(r"AKIA[0-9A-Z]{16}")

# string-interpolation-query, per language.
PY_SQL_RE = re.compile(r"""(execute|cursor)\s*\(\s*f["']""")
JS_SQL_RE = re.compile(r"(query|execute)\s*\(\s*`[^`]*(SELECT|INSERT|UPDATE|DELETE)")
GO_SQL_RE = re.compile(r"(Exec|Query|QueryRow)\s*\(\s*fmt\.Sprintf")

# dangerous-function (all languages).
DANGER_FN_RE = re.compile(
    r"\b(subprocess\.call\s*\(.*shell\s*=\s*True|child_process\.exec\s*\()"
)
# Unsafe deserialization: marshal.load(s) is always unsafe; yaml.load(...) is
# unsafe only WITHOUT an explicit Loader= (a safe loader makes it benign). Two
# stages, mirroring the fixed bash `grep -nE '...' | grep -vE 'Loader\s*='`
# (#183): a positive match on yaml.load(/marshal.load( that is NOT excluded by a
# Loader= on the same line.
UNSAFE_DESERIALIZE_RE = re.compile(r"\b(yaml\.load\s*\(|marshal\.loads?\s*\()")
LOADER_EXCLUDE_RE = re.compile(r"Loader\s*=")

# denylist-validation (all languages).
DENYLIST_RE = re.compile(
    r"(blacklist|blocklist|denylist|banned|forbidden)\s*=\s*\[", re.IGNORECASE
)


def strip_eol_cr(content: str) -> str:
    r"""One trailing CR off a line before it becomes evidence (#902, #980).

    Mirrors truncate_chars() in the bash fallback, which has stripped it since
    #902 -- same strip, same before-the-slice order. read_lines() deliberately
    KEEPS a CRLF's `\r` in the line so `$`-anchored regexes behave as they do
    under grep (#980); without this the retained `\r` would reach the TSV and
    the two runtimes' evidence would differ by one byte on any CRLF match.
    """
    return content[:-1] if content.endswith("\r") else content


def read_lines(path: str) -> list[str]:
    r"""PATH's lines under grep's line model: split on `\n` ONLY (#980).

    `newline=""` disables universal-newline translation. Without it a lone `\r`
    is rewritten to `\n` by read() BEFORE any split can see it, so even
    `.split("\n")` reports two lines where `grep -n` reports one -- the bash
    fallback reaches every line through grep, so grep's model is the contract.
    str.splitlines(), which this replaced, additionally splits on `\x0b`,
    `\x0c`, `\x1c`-`\x1e` and U+2028/2029, none of which grep treats as a
    separator.

    The trailing empty left by a final newline is dropped so the count matches
    `grep -n` at both ends (a file with no trailing newline keeps its last line;
    a file that is a bare newline still has one, empty, line).

    A CRLF's `\r` STAYS in the line, exactly as it does under grep -- stripping
    it here would silently change every `$`-anchored regex in every scanner.
    It comes off at the evidence cap instead, mirroring truncate_chars (#902).
    """
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def emit(path: str, line_no: int, category: str, label: str, content: str) -> None:
    """Write one TSV finding row: '<label>: <first 80 chars of the line>'."""
    evidence = label + ": " + strip_eol_cr(content)[:EVIDENCE_CAP]
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
        if UNSAFE_DESERIALIZE_RE.search(line) and not LOADER_EXCLUDE_RE.search(line):
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
            lines = read_lines(path)
        except OSError:
            continue
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
