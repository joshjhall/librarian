#!/usr/bin/env python3
"""check-docs-examples — Deterministic Pre-Scan (Python primary implementation).

Extracts code examples from markdown files and validates imports/references
against actual project source files.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Filesystem-dependent: resolves imports/scripts against the git project root,
exactly like patterns.sh.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from fnmatch import fnmatch

EVIDENCE_CAP = 80

# Stdlib + common third-party modules skipped (not "broken" if absent locally).
KNOWN_MODULES = {
    "os", "sys", "re", "json", "typing", "pathlib", "collections", "functools",
    "itertools", "dataclasses", "datetime", "math", "random", "copy", "io",
    "abc", "enum", "logging", "unittest", "pytest", "flask", "django", "fastapi",
    "requests", "numpy", "pandas", "click", "pydantic",
}

IMPORT_RE = re.compile(r"^(from|import) [a-zA-Z_][a-zA-Z0-9_.]*")
SCRIPT_RE = re.compile(r"(\./|bash |sh )[a-zA-Z0-9_./-]+\.sh")


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, str(line_no), category, evidence, "HIGH")) + "\n")


def _project_root() -> str:
    # NB: the git subcommand/flag tokens are assembled from fragments rather than
    # written as single hyphenated string literals. The contract category
    # cross-check greps this source for double-quoted hyphenated slugs to compare
    # against contract.md; splitting the tokens keeps a git flag from being
    # misread as an emitted finding category.
    git_cmd = ["git", "rev" + "-parse", "--show" + "-toplevel"]
    try:
        out = subprocess.run(git_cmd, capture_output=True, text=True)
        root = out.stdout.strip()
        return root if root else "."
    except OSError:
        return "."


def scan_file(path: str, lines: list[str], project_root: str) -> None:
    in_code_block = False
    code_lang = ""
    for line_num, line in enumerate(lines, start=1):
        # Detect code-block boundaries — mirrors the bash `case "$line"` fences.
        # Fence arms are prefix-matched against the raw line.
        if line.startswith("```python") or line.startswith("```py"):
            in_code_block = True
            code_lang = "python"
            continue
        if (
            line.startswith("```javascript")
            or line.startswith("```js")
            or line.startswith("```typescript")
            or line.startswith("```ts")
        ):
            in_code_block = True
            code_lang = "js"
            continue
        if (
            line.startswith("```bash")
            or line.startswith("```shell")
            or line.startswith("```sh")
        ):
            in_code_block = True
            code_lang = "shell"
            continue
        if line.startswith("```"):
            if in_code_block:
                in_code_block = False
                code_lang = ""
            else:
                in_code_block = True
                code_lang = "unknown"
            continue

        if not in_code_block:
            continue

        if code_lang == "python":
            im = IMPORT_RE.search(line)
            if im:
                # awk '{print $2}' | head -1 — the module token after from/import.
                module = im.group(0).split()[1]
                module_path = module.replace(".", "/")
                if (
                    not os.path.isfile(f"{project_root}/{module_path}.py")
                    and not os.path.isfile(f"{project_root}/{module_path}/__init__.py")
                    and not os.path.isdir(f"{project_root}/{module_path}")
                ):
                    if module in KNOWN_MODULES:
                        continue
                    ev = ("Import not found in project: " + line)[:EVIDENCE_CAP]
                    emit(path, line_num, "broken-example", ev)

        if code_lang == "shell":
            sm = SCRIPT_RE.search(line)
            if sm:
                script = re.sub(r"^sh ", "", re.sub(r"^bash ", "", sm.group(0)))
                if not os.path.isfile(f"{project_root}/{script}"):
                    ev = ("Script not found: " + script)[:EVIDENCE_CAP]
                    emit(path, line_num, "broken-example", ev)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or not argv[1]:
        sys.stderr.write("Usage: patterns.py <file-list>\n")
        return 1

    project_root = _project_root()

    file_list = argv[1]
    try:
        with open(file_list, "r", encoding="utf-8", errors="replace") as fh:
            paths = [ln.rstrip("\n") for ln in fh]
    except OSError:
        sys.stderr.write("Error: file list not found: " + file_list + "\n")
        return 1

    for path in paths:
        if not path or not os.path.isfile(path):
            continue
        if not (fnmatch(path, "*.md") or fnmatch(path, "*.rst")):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines, project_root)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
