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

    # Empty list → nothing to evaluate; emit nothing, exit 0 (issue #64).
    if not files:
        return 0

    project_root = _project_root()

    # --- Category: missing-root-doc ---
    for expected in ("README.md", "LICENSE", "CHANGELOG.md"):
        found = False
        if expected == "LICENSE":
            for variant in ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "LICENCE.md"):
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
