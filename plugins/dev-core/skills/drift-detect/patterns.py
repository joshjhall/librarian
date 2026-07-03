#!/usr/bin/env python3
"""drift-detect — Deterministic Pre-Scan (Python primary implementation).

Compares planned files (from an issue body) against actual changed files (from
git diff) to detect file-level drift.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:
  argv[1] = file containing actual changed file paths (one per line)
  argv[2] = file containing planned file paths (one per line)

This tool is the two-argument outlier in the pre-scan family (every other tool
takes a single file-list arg).

Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or a list file not found
"""

from __future__ import annotations

import os
import re
import sys

# Known side-effect files commonly modified as a consequence of other changes
# (not scope drift) — mirrors SIDE_EFFECT_PATTERNS in patterns.sh.
SIDE_EFFECT_PATTERNS = (
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "go.sum",
    "Cargo.lock",
    "Gemfile.lock",
    "poetry.lock",
    "composer.lock",
    ".gitignore",
)


def emit(name: str, category: str, evidence: str, certainty: str) -> None:
    """Emit one TSV row. drift-detect always reports line 0 (file-level)."""
    sys.stdout.write("\t".join((name, "0", category, evidence, certainty)) + "\n")


def _trim(s: str) -> str:
    """sed 's/^[[:space:]]*//;s/[[:space:]]*$//' — strip leading/trailing space."""
    return re.sub(r"^[ \t]*", "", re.sub(r"[ \t]*$", "", s))


def _read_lines(path: str) -> list[str]:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return [ln.rstrip("\n") for ln in fh]


def _basename_no_ext(path: str) -> str:
    """basename PATH | sed 's/\\.[^.]*$//' — file name minus a final extension."""
    base = path.rsplit("/", 1)[-1]
    return re.sub(r"\.[^.]*$", "", base)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <actual-files> <planned-files>\n")
        return 1
    if len(argv) < 3 or not argv[2]:
        sys.stderr.write("Usage: patterns.py <actual-files> <planned-files>\n")
        return 1

    actual_path, planned_path = argv[1], argv[2]
    if not os.path.isfile(actual_path):
        sys.stderr.write("Error: actual files list not found: " + actual_path + "\n")
        return 1
    if not os.path.isfile(planned_path):
        sys.stderr.write("Error: planned files list not found: " + planned_path + "\n")
        return 1

    actual_raw = _read_lines(actual_path)
    planned_raw = _read_lines(planned_path)

    # --- Category: planned-not-touched ---
    # A planned file (or a file within a planned directory) absent from the diff.
    for planned in planned_raw:
        if not planned:
            continue
        planned = _trim(planned)
        if not planned:
            continue
        found = False
        for actual in actual_raw:
            if not actual:
                continue
            if actual == planned or actual.startswith(planned + "/"):
                found = True
                break
        if not found:
            emit(
                planned,
                "planned-not-touched",
                "Planned file not found in git diff",
                "HIGH",
            )

    # --- Category: unplanned-modification ---
    # A changed file not in the plan (side-effect / test → LOW; else MEDIUM).
    for actual in actual_raw:
        if not actual:
            continue
        found = False
        for planned in planned_raw:
            if not planned:
                continue
            planned = _trim(planned)
            if not planned:
                continue
            if actual == planned or actual.startswith(planned + "/"):
                found = True
                break
        if found:
            continue

        is_side_effect = any(actual.endswith(pat) for pat in SIDE_EFFECT_PATTERNS)

        is_test_for_planned = False
        for planned in planned_raw:
            if not planned:
                continue
            planned = _trim(planned)
            if not planned:
                continue
            pb = _basename_no_ext(planned)
            # case: *test*<pb>* | *<pb>*test* | *<pb>*spec*
            if (
                re.search(r"test.*" + re.escape(pb), actual)
                or re.search(re.escape(pb) + r".*test", actual)
                or re.search(re.escape(pb) + r".*spec", actual)
            ):
                is_test_for_planned = True
                break

        if is_side_effect or is_test_for_planned:
            emit(
                actual,
                "unplanned-modification",
                "Modified but not in plan (side-effect or test)",
                "LOW",
            )
        else:
            emit(
                actual,
                "unplanned-modification",
                "Modified but not listed in plan",
                "MEDIUM",
            )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
