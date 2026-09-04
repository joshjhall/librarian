#!/usr/bin/env python3
"""check-docs-staleness — Deterministic Pre-Scan (Python primary implementation).

Detects potential staleness indicators in documentation files using regex
patterns. Results are passed to the LLM for confirmation/dismissal.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

The staleness threshold (CHECK_STALENESS_MONTHS, default 12) and the current
date drive the expired-date comparison, exactly as in patterns.sh.
"""

from __future__ import annotations

import datetime
import os
import re
import sys

EVIDENCE_CAP = 80


def _int_env(name: str, default: int) -> int:
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


DATE_RE = re.compile(r"\b(20[0-9]{2})[-/](0[1-9]|1[0-2])[-/](0[1-9]|[12][0-9]|3[01])\b")
YEAR_RE = re.compile(r"20[0-9]{2}")
YEARMONTH_RE = re.compile(r"20[0-9]{2}[-/](0[1-9]|1[0-2])")
MONTH_TAIL_RE = re.compile(r"(0[1-9]|1[0-2])$")
VERSION_RE = re.compile(r"\bv?[0-9]+\.[0-9]+\.[0-9]+\b")
STALE_MARKER_RE = re.compile(
    r"(TODO|FIXME|XXX|HACK|WORKAROUND).*"
    r"(updat|outdat|stale|obsolete|deprecat|remov|old |was )",
    re.IGNORECASE,
)
URL_RE = re.compile(r'https?://[^ )>"]+')
URL_DEPRECATED_RE = re.compile(
    r"(deprecated|removed|old|legacy|archive|sunset)", re.IGNORECASE
)


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, str(line_no), category, evidence, "HIGH")) + "\n")


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

    now = datetime.datetime.now()
    current_year = now.year
    current_month = now.month
    staleness_months = _int_env("CHECK_STALENESS_MONTHS", 12)
    threshold_months = current_year * 12 + current_month - staleness_months

    def is_date_stale(year: int, month: int) -> bool:
        return (year * 12 + month) < threshold_months

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
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue

        for idx, content in enumerate(lines, start=1):
            # --- Category: expired-date ---
            if DATE_RE.search(content):
                year_m = YEAR_RE.search(content)
                ymatch = YEARMONTH_RE.search(content)
                month = None
                if ymatch:
                    mt = MONTH_TAIL_RE.search(ymatch.group(0))
                    month = mt.group(0) if mt else None
                if year_m and month:
                    month_num = int(month.lstrip("0") or "0")
                    if is_date_stale(int(year_m.group(0)), month_num):
                        emit(
                            path,
                            idx,
                            "expired-date",
                            f"Date reference older than {staleness_months} months: "
                            + content[:EVIDENCE_CAP],
                        )

            # --- Category: outdated-reference (version references) ---
            if VERSION_RE.search(content):
                if not ("### [" in content or "## [" in content or "- v" in content):
                    emit(
                        path,
                        idx,
                        "outdated-reference",
                        "Version reference to verify: " + content[:EVIDENCE_CAP],
                    )

            # --- Category: stale-comment ---
            if STALE_MARKER_RE.search(content):
                emit(
                    path,
                    idx,
                    "stale-comment",
                    "Staleness marker: " + content[:EVIDENCE_CAP],
                )

            # --- Category: outdated-reference (deprecated URLs) ---
            if URL_RE.search(content) and URL_DEPRECATED_RE.search(content):
                emit(
                    path,
                    idx,
                    "outdated-reference",
                    "URL with deprecation indicators: " + content[:EVIDENCE_CAP],
                )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
