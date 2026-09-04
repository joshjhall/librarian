#!/usr/bin/env python3
"""check-docs-organization — Deterministic Pre-Scan (Python primary impl).

Checks for missing standard root documents and directories without READMEs. The
checks are DRIVEN BY the passed file list: an empty list produces empty output
and exit 0 (a deterministic pre-scan must never emit project-level findings on
empty input — issue #64). When the list is non-empty the root-document check runs
against the project root, and the directory-README check runs only for
directories that contain a listed file (capped at the configured depth).

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Filesystem- and git-dependent (probes the project root and touched dirs).
"""

from __future__ import annotations

import fnmatch as _fnmatch
import os
import re
import subprocess
import sys

MAX_DEPTH_DEFAULT = 2
MIN_FILES_DEFAULT = 5


def _int_env(name: str, default: int) -> int:
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


def emit(name: str, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((name, "1", category, evidence, "HIGH")) + "\n")


def _project_root() -> str:
    git_cmd = ["git", "rev" + "-parse", "--show" + "-toplevel"]
    try:
        out = subprocess.run(git_cmd, capture_output=True, text=True)
        root = out.stdout.strip()
        return root if root else "."
    except OSError:
        return "."


def _trim(s: str) -> str:
    """Bash trims surrounding whitespace via `${_line#...}` / `${_line%...}`."""
    return s.strip()


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
    if not os.path.isfile(file_list):
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
        files = [t for t in (_trim(ln.rstrip("\n")) for ln in fh) if t]

    if assert_file_list_shape(files, file_list, os.path.basename(__file__)):
        return 1

    # Empty list → nothing to evaluate; emit nothing, exit 0 (issue #64).
    if not files:
        return 0

    project_root = _project_root()

    # --- Category: missing-root-doc ---
    for expected in ("README.md", "LICENSE", "CHANGELOG.md"):
        found = False
        if expected == "LICENSE":
            for variant in (
                "LICENSE",
                "LICENSE.md",
                "LICENSE.txt",
                "LICENCE",
                "LICENCE.md",
            ):
                if os.path.isfile(f"{project_root}/{variant}"):
                    found = True
                    break
        else:
            found = os.path.isfile(f"{project_root}/{expected}")
        if not found:
            emit(project_root, "missing-root-doc", f"Missing standard file: {expected}")

    # --- Category: missing-dir-readme ---
    max_depth = _int_env("CHECK_ORG_README_DEPTH", MAX_DEPTH_DEFAULT)
    min_files = _int_env("CHECK_ORG_MIN_FILES", MIN_FILES_DEFAULT)

    # Unique dirs of the listed files (absolute), sorted (matches sort -u).
    dirs = set()
    for f in files:
        abs_path = f if f.startswith("/") else f"{project_root}/{f}"
        # dirname
        d = abs_path.rsplit("/", 1)[0] if "/" in abs_path else "."
        dirs.add(d)

    for d in sorted(dirs):
        if not d:
            continue
        if d == project_root:
            continue
        if not os.path.isdir(d):
            continue
        # Only under project root.
        if not d.startswith(project_root + "/"):
            continue
        # Depth check: number of path segments below the root.
        rel = d[len(project_root) + 1 :] if d.startswith(project_root + "/") else d
        depth = len(rel.split("/"))
        if depth > max_depth:
            continue
        # Skip excluded/generated trees (globs mirror the bash `case`).
        if (
            _fnmatch.fnmatchcase(d, "*/.*")
            or _fnmatch.fnmatchcase(d, "*/node_modules/*")
            or _fnmatch.fnmatchcase(d, "*/vendor/*")
            or _fnmatch.fnmatchcase(d, "*/__pycache__/*")
            or _fnmatch.fnmatchcase(d, "*/dist/*")
            or _fnmatch.fnmatchcase(d, "*/build/*")
        ):
            continue
        # Skip if a README exists.
        if (
            os.path.isfile(f"{d}/README.md")
            or os.path.isfile(f"{d}/README.rst")
            or os.path.isfile(f"{d}/README")
        ):
            continue
        # Count meaningful files (top level only; exclude hidden/generated) —
        # `find "$dir" -maxdepth 1 -type f -not -name '.*' -not -name '*.pyc'
        #  -not -name '*.o' | wc -l`.
        try:
            entries = os.listdir(d)
        except OSError:
            continue
        count = 0
        for name in entries:
            full = os.path.join(d, name)
            if not os.path.isfile(full):
                continue
            if name.startswith("."):
                continue
            if _fnmatch.fnmatchcase(name, "*.pyc") or _fnmatch.fnmatchcase(name, "*.o"):
                continue
            count += 1
        if count >= min_files:
            relative_dir = re.sub("^" + re.escape(project_root) + "/", "", d)
            emit(
                d,
                "missing-dir-readme",
                f"Directory {relative_dir}/ has {count} files but no README",
            )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
