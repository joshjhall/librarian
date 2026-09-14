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


# Stdlib + common third-party modules skipped (not "broken" if absent locally).
KNOWN_MODULES = {
    "os",
    "sys",
    "re",
    "json",
    "typing",
    "pathlib",
    "collections",
    "functools",
    "itertools",
    "dataclasses",
    "datetime",
    "math",
    "random",
    "copy",
    "io",
    "abc",
    "enum",
    "logging",
    "unittest",
    "pytest",
    "flask",
    "django",
    "fastapi",
    "requests",
    "numpy",
    "pandas",
    "click",
    "pydantic",
}

IMPORT_RE = re.compile(r"^(from|import) [a-zA-Z_][a-zA-Z0-9_.]*")
SCRIPT_RE = re.compile(r"(\./|bash |sh )[a-zA-Z0-9_./-]+\.sh")


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
                    ev = truncate_chars(
                        strip_eol_cr(("Import not found in project: " + line))
                    )
                    emit(path, line_num, "broken-example", ev)

        if code_lang == "shell":
            sm = SCRIPT_RE.search(line)
            if sm:
                script = re.sub(r"^sh ", "", re.sub(r"^bash ", "", sm.group(0)))
                if not os.path.isfile(f"{project_root}/{script}"):
                    ev = truncate_chars(strip_eol_cr(("Script not found: " + script)))
                    emit(path, line_num, "broken-example", ev)


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

    project_root = _project_root()

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
        if not (fnmatch(path, "*.md") or fnmatch(path, "*.rst")):
            continue
        try:
            lines = read_lines(path)
        except OSError:
            continue
        scan_file(path, lines, project_root)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
