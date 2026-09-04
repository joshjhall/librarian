#!/usr/bin/env python3
"""check-docs-deadlinks — Deterministic Pre-Scan (Python primary implementation).

Detects broken relative links and anchors in documentation files. Does NOT
perform HTTP requests for external URLs.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Filesystem-dependent: resolves relative link targets against each document's
directory, exactly like patterns.sh.
"""

from __future__ import annotations

import os
import re
import sys

EVIDENCE_CAP = 80

LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
LINK_TARGET_RE = re.compile(r"\]\([^)]+\)")
ANCHOR_LINK_RE = re.compile(r"\[([^\]]*)\]\(#([^)]+)\)")
ANCHOR_TARGET_RE = re.compile(r"\]\(#[^)]+\)")
URL_RE = re.compile(r'https?://[^ )>"]+')
URL_SUSPICIOUS_RE = re.compile(
    r"(deprecated|sunset|eol|end-of-life|removed|legacy)", re.IGNORECASE
)


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, str(line_no), category, evidence, "HIGH")) + "\n")


def scan_file(path: str, lines: list[str]) -> None:
    file_dir = path.rsplit("/", 1)[0] if "/" in path else "."

    for idx, content in enumerate(lines, start=1):
        # --- Category: broken-relative-link ---
        if LINK_RE.search(content):
            m = LINK_TARGET_RE.search(content)  # head -1
            if m:
                # sed 's/^](//' ; sed 's/)$//'
                target = re.sub(r"\)$", "", re.sub(r"^\]\(", "", m.group(0)))
                if not (
                    target == ""
                    or target.startswith("http://")
                    or target.startswith("https://")
                    or target.startswith("mailto:")
                    or target.startswith("#")
                    or target.startswith("ftp://")
                ):
                    target_file = re.sub(r"#.*", "", target)  # strip anchor
                    if target_file:
                        resolved = file_dir + "/" + target_file
                        if not os.path.exists(resolved):
                            ev = ("Link target not found: " + target)[:EVIDENCE_CAP]
                            emit(path, idx, "broken-relative-link", ev)

        # --- Category: broken-anchor ---
        if ANCHOR_LINK_RE.search(content):
            m = ANCHOR_TARGET_RE.search(content)  # head -1
            if m:
                anchor = re.sub(r"\)$", "", re.sub(r"^\]\(#", "", m.group(0)))
                if anchor:
                    heading_pattern = anchor.replace("-", " ")
                    hp_re = re.compile(
                        r"^#{1,6} .*" + re.escape(heading_pattern), re.IGNORECASE
                    )
                    # Guard: re.escape neutralizes regex metachars; the bash uses
                    # the raw string in grep -E, but for our fixture corpus these
                    # anchors are plain words. Search the whole file.
                    if not any(hp_re.search(ln) for ln in lines):
                        ev = (f"Anchor #{anchor} has no matching heading in file")[
                            :EVIDENCE_CAP
                        ]
                        emit(path, idx, "broken-anchor", ev)

        # --- Category: suspicious-external-link ---
        # grep -noE 'https?://...' emits ONE row per URL match on the line, each
        # prefixed with the line number; the certainty filter keeps only URLs
        # whose text carries a deprecation indicator.
        for um in URL_RE.finditer(content):
            url = um.group(0)
            if URL_SUSPICIOUS_RE.search(url):
                ev = ("Suspicious URL: " + url)[:EVIDENCE_CAP]
                emit(path, idx, "suspicious-external-link", ev)


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
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
