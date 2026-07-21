#!/usr/bin/env python3
"""check-lifecycle — Deterministic Pre-Scan (Python primary implementation).

Detects resource-lifecycle CANDIDATES catchable by a single-line regex:
subprocess spawn sites, SIGTERM/terminate sites, unscoped handle acquisitions,
and listener/timer registrations. These are suspicious on one line but the paired
release may live elsewhere in the scope, so every row is emitted at certainty
MEDIUM — a candidate the LLM pass-2 confirms or dismisses, never an auto-fix.
The judgment-heavy categories (`unjoined-worker`, `unbounded-growth`) are LLM-only
and produced by pass-2, not here.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh and tests/validate-prescan-differential.sh
(whole-repo diff), and the classification behavior by
tests/validate-lifecycle-detectors.sh. See CLAUDE.md § Key conventions.

The is_test_file() helper mirrors the segment-anchored check-code-health /
ship-issue copies for classification uniformity (it is NOT wired into the
validate-shared-scanner-sync.sh drift gate, which covers only the
check-code-health <-> ship-issue pair — this copy stands alone). check-lifecycle
skips test files WHOLESALE (lifecycle shortcuts in test scaffolding are
expected), so the helper gates the whole per-file scan rather than a single
category.

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

CERTAINTY = "MEDIUM"
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
    is_test_file() block in patterns.sh (segment-anchored so contest.py /
    latest.js are NOT matched, while tests/helper.py IS). PATH-only:
    content-colocated tests are not this function's concern."""
    for seg in ("tests", "test", "__tests__", "spec", "__pycache__"):
        if path.startswith(seg + "/") or ("/" + seg + "/") in path:
            return True
    base = path.rsplit("/", 1)[-1]
    if fnmatch(base, "test_*.*"):
        return True
    for pat in ("*_test.*", "*_spec.*", "*.test.*", "*.spec.*"):
        if fnmatch(base, pat):
            return True
    return False


def _bash_read_content(line: str) -> str:
    """Reproduce the `grep -n | while IFS=: read -r line_num content` splitting so
    evidence is byte-identical to the bash impl. `content` is the remainder after
    the first colon with the last (empty) field dropped — observable only as: a
    single trailing colon is stripped IFF the line has exactly one colon and ends
    with it. Verified against bash across a corpus."""
    if line.count(":") == 1 and line.endswith(":"):
        return line[:-1]
    return line


def emit(path: str, line_no: int, category: str, label: str, content: str) -> None:
    """Write one TSV finding row: '<label>: <first 80 chars of the code line>'."""
    evidence = label + ": " + _bash_read_content(content)[:EVIDENCE_CAP]
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


# Per-category labels — kept ONE string per category across every language arm so
# the bash fallback can reuse the identical literal (byte-parity insurance).
L_SUBPROCESS = "Subprocess spawned without visible reap"
L_TERMINATE = "Terminate without kill escalation"
L_HANDLE = "Handle acquired without scoped close"
L_LISTENER = "Listener/timer registered without visible removal"


def scan_file(path: str, lines: list[str]) -> None:
    # Lifecycle shortcuts in test scaffolding are expected — skip test files
    # WHOLESALE (unlike check-code-health, which only gates debug-statement).
    if is_test_file(path):
        return
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    for idx, line in enumerate(lines, start=1):
        if ext == "swift":
            if re.search(r"\bProcess\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\.terminate\s*\(\)", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"=\s*FileHandle\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            if re.search(r"\.addObserver\s*\(|\bscheduledTimer\b", line):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
        elif ext == "py":
            if re.search(r"\b(subprocess\.)?Popen\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\.terminate\s*\(\)", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"=\s*open\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
        elif ext in ("js", "ts", "jsx", "tsx"):
            if re.search(
                r"\b(spawn|spawnSync|exec|execFile|execFileSync|execSync)\s*\(", line
            ):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\.terminate\s*\(\)", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(
                r"=\s*fs\.(openSync|createReadStream|createWriteStream)\s*\(", line
            ):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)
            if re.search(r"\.addEventListener\s*\(|\bsetInterval\s*\(|\.on\s*\(", line):
                emit(path, idx, "unpaired-listener", L_LISTENER, line)
        elif ext == "go":
            if re.search(r"\bexec\.Command\s*\(", line):
                emit(path, idx, "unreaped-subprocess", L_SUBPROCESS, line)
            if re.search(r"\bos\.Interrupt\b", line):
                emit(path, idx, "terminate-without-kill", L_TERMINATE, line)
            if re.search(r"\bos\.(Open|Create)\s*\(", line):
                emit(path, idx, "unclosed-handle", L_HANDLE, line)


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
