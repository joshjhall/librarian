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


def truncate_chars(s: str) -> str:
    """First EVIDENCE_CAP characters of `s`, with a marker when it actually cut.

    THE MARKER IS THE POINT (#786). A silently trimmed evidence field reads as a
    complete one, so a reader reasons about a line that does not end where the
    text stops. The ellipsis REPLACES the last character rather than extending
    past the cap, so the column stays bounded at exactly EVIDENCE_CAP.

    Byte-for-byte equivalent to `truncate_chars` in the sibling patterns.sh --
    tests/validate-python-ports.sh pins the two runtimes' TSV output.
    """
    if len(s) <= EVIDENCE_CAP:
        return s
    return s[: EVIDENCE_CAP - 1] + "\u2026"


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
# The `f?` is the #684 fix: a flat trailing `\b` rejected `t.Errorf`/`t.Fatalf`/
# `t.Logf` — Go's dominant assertion idioms — because `f` is a word character, so
# a test file using only those was reported as having NO assertions at HIGH.
#
# The formatting variants are spelled out rather than the boundary simply being
# dropped. Dropping it admits ANY identifier with one of these prefixes
# (`t.ErrorHandlerConfig`), which is a wider match than the fix needs; `f?` plus
# a kept `\b` accepts exactly the real idioms. `Run`/`Helper` have no `f` form
# and so keep a bare boundary.
#
# Kept in lockstep with the bash fallback in patterns.sh — both carried the
# identical original defect, which is why validate-python-ports.sh stayed green
# through it (it pins same-OUTPUT, not same-intent).
GO_ASSERT_RE = re.compile(
    r"\b(t\.(Error|Fatal|Log)f?|t\.(Run|Helper)|assert\.|require\.)\b"
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
                "Stub/placeholder: " + truncate_chars(strip_eol_cr(content)),
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
                        "Empty function body: " + truncate_chars(strip_eol_cr(content)),
                    )
        elif ext in ("ts", "js", "tsx", "jsx"):
            if JS_EMPTY_BODY_RE.search(content):
                emit(
                    path,
                    str(idx),
                    "empty-body",
                    "Empty function body: " + truncate_chars(strip_eol_cr(content)),
                )
        elif ext == "go":
            if GO_EMPTY_BODY_RE.search(content):
                emit(
                    path,
                    str(idx),
                    "empty-body",
                    "Empty function body: " + truncate_chars(strip_eol_cr(content)),
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
        try:
            lines = read_lines(path)
        except OSError:
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
