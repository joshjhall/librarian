#!/usr/bin/env python3
"""check-code-health — Deterministic Pre-Scan (Python primary implementation).

Detects code-health patterns catchable by regex: tech-debt markers, debug
statements, and empty error handlers. Results are passed to the LLM for
context-dependent confirmation/dismissal.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh, and the classification behavior by
tests/validate-scanner-classification.sh. See CLAUDE.md § Key conventions.

Note on the shared bash regions: patterns.sh carries two `>>> shared:` blocks
(`is-test-file`, `debug-statement-scan`) kept byte-identical with
ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh. Those
blocks live in the BASH fallback, which is unchanged — so the sync gate is
unaffected by this port. This file re-expresses the same logic in Python; the
parity test guarantees it stays equivalent to the bash (and thus to the shared
copy).

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

# Non-source files skipped wholesale (lock files before generic extensions) —
# mirrors the leading `case "$file"` skip arms in patterns.sh.
SKIP_GLOBS = (
    "*.lock",
    "*lock.json",
    "*go.sum",
    "*.md",
    "*.txt",
    "*.json",
    "*.yaml",
    "*.yml",
    "*.toml",
    "*.ini",
    "*.cfg",
    "*.conf",
)


def is_test_file(path: str) -> bool:
    """Return True if PATH is a test file by path/name convention. Mirrors the
    `>>> shared:is-test-file` block in patterns.sh exactly (segment-anchored so
    contest.py / latest.js are NOT matched, while tests/helper.py IS). PATH-only:
    content-colocated tests are not this function's concern.

    The name arms match on the BASENAME, which is the semantics the bash copies
    adopted in #568: a bash `case` glob's `*` crosses `/`, so their old
    `*/test_*.*` arm also matched a DIRECTORY named `test_helpers/`. This impl
    was already basename-anchored and so was already correct — the bash side
    moved to match it, not the reverse."""
    # Directory-segment arms: a `tests`/`test`/`__tests__`/`spec`/`__pycache__`
    # segment anywhere in the path (leading or after a slash).
    for seg in ("tests", "test", "__tests__", "spec", "__pycache__"):
        if path.startswith(seg + "/") or ("/" + seg + "/") in path:
            return True
    # Basename arms: test_*.*  and  *_test.* / *_spec.* / *.test.* / *.spec.*
    base = path.rsplit("/", 1)[-1]
    if fnmatch(base, "test_*.*"):
        return True
    for pat in ("*_test.*", "*_spec.*", "*.test.*", "*.spec.*"):
        if fnmatch(base, pat):
            return True
    return False


def is_scanner_pattern_line(line: str) -> bool:
    """Return True when LINE is a detector's own regex SOURCE rather than code
    (#599). Mirrors the `>>> shared:scanner-pattern-line` block in patterns.sh.

    The debug-statement patterns are written as literals inside the scanners'
    own `grep`/`re.search` calls, so scanning a diff that touches a scanner file
    makes those literals match themselves and emit HIGH-certainty rows for a
    guaranteed non-problem.

    LINE-scoped, not path-scoped: a real `console.log` or `print(` left in a
    scanner file must still fire, so only the invocation line carrying the
    quoted pattern is suppressed."""
    # bash form: `command grep -niE -- '<pattern>' "$file"` — any short-flag
    # cluster, but the `--` end-of-options marker and an opening quote are
    # required, so a plain filtering grep with no pattern literal still scans.
    if re.search(r"grep -[a-zA-Z]* -- ['\"]", line):
        return True
    # python form: re.search(r"..."), re.match(r'...'), re.compile(r"...")
    if re.search(r"re\.(search|match|compile)\(r['\"]", line):
        return True
    return False


def emit(path: str, line_no: int, category: str, label: str, content: str) -> None:
    """Write one TSV finding row: '<label>: <first 80 chars of the code line>'."""
    evidence = label + ": " + content[:EVIDENCE_CAP]
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


def _first_nonblank_after(lines: list[str], idx_1: int) -> str:
    """First non-blank line (any content) at or after 1-indexed idx_1, matching
    `sed -n 'N,$p' | grep -m1 -E '\\S' | head -1`. Empty string if none."""
    for ln in lines[idx_1 - 1 :]:
        if re.search(r"\S", ln):
            return ln
    return ""


def scan_file(path: str, lines: list[str]) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    test_file = is_test_file(path)

    for idx, line in enumerate(lines, start=1):
        # --- Category: tech-debt-marker (all source files) ---
        if re.search(r"\b(TODO|FIXME|HACK|XXX|WORKAROUND)\b", line, re.IGNORECASE):
            emit(path, idx, "tech-debt-marker", "Tech debt marker", line)

        # --- Category: debug-statement (non-test files only) ---
        # Mirrors the `>>> shared:debug-statement-scan` block, per-language.
        # Scanner pattern literals are skipped first, matching the bash copies'
        # `is_scanner_pattern_line "$content" && continue` in every arm (#599).
        if not test_file and not is_scanner_pattern_line(line):
            if ext == "py":
                if re.search(r"^\s*print\(", line) and not re.search(
                    r"(logging|logger|log\.)", line
                ):
                    emit(path, idx, "debug-statement", "Debug print statement", line)
                if re.search(r"^\s*(breakpoint\(\)|import pdb|pdb\.set_trace)", line):
                    emit(path, idx, "debug-statement", "Debugger statement", line)
            elif ext in ("js", "ts", "jsx", "tsx", "mjs", "cjs"):
                if re.search(r"^\s*console\.(log|debug|warn|info|trace)\(", line):
                    emit(path, idx, "debug-statement", "Console debug statement", line)
                if re.search(r"^\s*debugger\s*;?\s*$", line):
                    emit(path, idx, "debug-statement", "Debugger keyword", line)
            elif ext == "rb":
                if re.search(r"^\s*(binding\.pry|binding\.irb|byebug)\b", line):
                    emit(path, idx, "debug-statement", "Ruby debugger", line)
            elif ext == "go":
                if re.search(r"^\s*fmt\.Print(ln|f)?\(", line):
                    emit(path, idx, "debug-statement", "Debug print statement", line)
            elif ext in ("java", "kt"):
                if re.search(r"^\s*System\.(out|err)\.print(ln)?\(", line):
                    emit(path, idx, "debug-statement", "Debug print statement", line)

        # --- Category: empty-handler (all files) ---
        if ext == "py":
            if re.search(r"^\s*except", line):
                nxt = _first_nonblank_after(lines, idx + 1)
                if re.search(r"^\s*pass\s*$", nxt):
                    emit(path, idx, "empty-handler", "Empty except block (pass)", line)
        elif ext in ("js", "ts", "jsx", "tsx"):
            if re.search(r"catch\s*\([^)]*\)\s*\{\s*\}", line):
                emit(path, idx, "empty-handler", "Empty catch block", line)
        elif ext in ("java", "kt"):
            if re.search(r"catch\s*\([^)]*\)\s*\{\s*\}", line):
                emit(path, idx, "empty-handler", "Empty catch block", line)
        elif ext == "rb":
            if re.search(r"^\s*rescue\b", line):
                nxt = _first_nonblank_after(lines, idx + 1)
                if re.search(r"^\s*(end|rescue)\s*$", nxt):
                    emit(path, idx, "empty-handler", "Empty rescue block", line)
        elif ext == "go":
            if re.search(r"if err != nil\s*\{\s*\}", line):
                emit(path, idx, "empty-handler", "Swallowed error", line)


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
