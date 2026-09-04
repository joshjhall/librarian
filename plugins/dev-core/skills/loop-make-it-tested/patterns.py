#!/usr/bin/env python3
"""loop-make-it-tested — Deterministic Pre-Scan (Python primary implementation).

Detects test coverage gaps: public functions without test files, test files
without assertions, source modules without test counterparts.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Filesystem-dependent: probes for sibling test files and greps them, exactly like
patterns.sh, so the two impls agree on the same working tree.
"""

from __future__ import annotations

import glob as _glob
import os
import re
import sys
from fnmatch import fnmatch

# Test/non-source files skipped wholesale (substring globs) — leading bash `case`.
SKIP_GLOBS = (
    "*test*",
    "*spec*",
    "*__pycache__*",
    "*.md",
    "*.yml",
    "*.yaml",
    "*.json",
    "*.toml",
)

PY_PUBLIC_FUNC_RE = re.compile(r"^def [a-zA-Z][a-zA-Z0-9_]*\(")
GO_EXPORTED_FUNC_RE = re.compile(r"^func [A-Z][a-zA-Z0-9]*\(")

# --- module public-API policy (#606) ----------------------------------------
# Port of patterns.sh's py_public_symbols_gate / py_symbol_is_public. Kept as a
# structural mirror of the bash rather than rewritten idiomatically (e.g. via
# ast.parse), because the TSV parity pinned by tests/validate-python-ports.sh is
# only as good as the two impls' agreement on EVERY edge case, and matching the
# grep/awk semantics line-for-line is what makes that auditable.
PY_ALL_ASSIGN_RE = re.compile(r"^__all__([ \t]*:[^=]*)?[ \t]*=")
PY_ALL_NAME_RE = re.compile(r"\"[a-zA-Z_][a-zA-Z0-9_]*\"|'[a-zA-Z_][a-zA-Z0-9_]*'")
# Anchored at column 0: a guard nested inside a function or class is not the
# module's entry point and must not gate the whole file.
PY_MAIN_GUARD_RE = re.compile(r"^if[ \t]+__name__[ \t]*==[ \t]*[\"']__main__[\"']")


def _py_public_symbols_gate(lines: list[str]) -> str:
    """This MODULE's public-API policy — "all:<names>", "none", or "open".

    A `main()`-guarded CLI script exposes no importable API, so its top-level
    helpers are not public API and no test is expected to name them. An explicit
    `__all__` overrides the guard in both directions: it is a positive
    declaration, and the escape hatch for a module that is both CLI and library.
    """
    for idx, line in enumerate(lines):
        if not PY_ALL_ASSIGN_RE.search(line):
            continue
        # Accumulate from the `=` to the closing bracket. The first line is
        # tested for the terminator itself, so a single-line `__all__ = ["x"]`
        # stops there instead of running on to the next `]` in the file.
        chunk = line[line.index("=") + 1 :]
        collected = [chunk]
        if not re.search(r"[])]", chunk):
            for cont in lines[idx + 1 :]:
                collected.append(cont)
                if re.search(r"[])]", cont):
                    break
        names = [
            m.group(0).strip("\"'")
            for m in PY_ALL_NAME_RE.finditer("\n".join(collected))
        ]
        return "all:" + "".join(n + " " for n in names)

    if any(PY_MAIN_GUARD_RE.search(ln) for ln in lines):
        return "none"

    return "open"


def _py_symbol_is_public(symbol: str, gate: str) -> bool:
    """True when <symbol> is public API under <gate>."""
    if gate == "none":
        return False
    if gate.startswith("all:"):
        # Padded whole-word match, so `check_mcp` cannot match `check_mcp_config`.
        return f" {symbol} " in f" {gate[len('all:') :]} "
    return True


def emit(path: str, line_no: str, category: str, evidence: str) -> None:
    sys.stdout.write("\t".join((path, line_no, category, evidence, "HIGH")) + "\n")


def _word_in_file(fpath: str, word: str) -> bool:
    """`grep -q "\\b<word>\\b" fpath` — the word (as a \\b-bounded token) occurs."""
    pat = re.compile(r"\b" + re.escape(word) + r"\b")
    try:
        with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if pat.search(line):
                    return True
    except OSError:
        return False
    return False


def _word_in_any(globs: list[str], word: str) -> bool:
    """`grep -rql "\\b<word>\\b" <globs...>` — the word occurs in ANY matched file.
    Non-existent globs expand to nothing (grep would error to /dev/null → no match)."""
    pat = re.compile(r"\b" + re.escape(word) + r"\b")
    for g in globs:
        for fpath in _glob.glob(g):
            try:
                with open(fpath, "r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if pat.search(line):
                            return True
            except OSError:
                continue
    return False


def scan_file(path: str, lines: list[str]) -> None:
    base = path.rsplit("/", 1)[-1]
    dirname = path.rsplit("/", 1)[0] if "/" in path else "."
    name_no_ext = base.rsplit(".", 1)[0] if "." in base else base
    ext = base.rsplit(".", 1)[-1] if "." in base else ""

    # --- Category: missing-test-file ---
    has_test = False
    if ext == "py":
        for tp in (
            f"{dirname}/test_{name_no_ext}.py",
            f"{dirname}/tests/test_{name_no_ext}.py",
            f"{dirname}/../tests/test_{name_no_ext}.py",
            f"{dirname}/{name_no_ext}_test.py",
        ):
            if os.path.isfile(tp):
                has_test = True
                break
    elif ext in ("ts", "js", "tsx", "jsx"):
        for suffix in ("test", "spec"):
            for tp in (
                f"{dirname}/{name_no_ext}.{suffix}.{ext}",
                f"{dirname}/__tests__/{name_no_ext}.{suffix}.{ext}",
                f"{dirname}/../__tests__/{name_no_ext}.{suffix}.{ext}",
            ):
                if os.path.isfile(tp):
                    has_test = True
                    break
            if has_test:
                break
    elif ext == "go":
        if os.path.isfile(f"{dirname}/{name_no_ext}_test.go"):
            has_test = True
    elif ext == "rs":
        if any(re.search(r"#\[cfg\(test\)\]", ln) for ln in lines):
            has_test = True
        elif os.path.isdir(f"{dirname}/../tests"):
            has_test = True

    if not has_test:
        emit(path, "1", "missing-test-file", f"No test file found for {base}")

    # --- Category: untested-public-api ---
    if ext == "py":
        # Resolved ONCE per file: the policy is a property of the module, not of
        # the symbol (#606).
        py_gate = _py_public_symbols_gate(lines)
        for idx, content in enumerate(lines, start=1):
            if not PY_PUBLIC_FUNC_RE.search(content):
                continue
            m = re.search(r"^def ([a-zA-Z][a-zA-Z0-9_]*)", content)
            func_name = m.group(1) if m else ""
            # Not public API for this module — no test is EXPECTED to name it,
            # so "no tests reference" is not a finding.
            if not _py_symbol_is_public(func_name, py_gate):
                continue
            # The third glob mirrors pre-review-gates.sh, whose py arm has
            # always had it — a src/ module tested from a sibling tests/ tree is
            # the commonest layout there is, and without it that whole shape
            # reported HIGH (#606).
            if not _word_in_any(
                [
                    f"{dirname}/test_*.py",
                    f"{dirname}/tests/test_*.py",
                    f"{dirname}/../tests/test_*.py",
                ],
                func_name,
            ):
                ev = content[:60]
                emit(
                    path,
                    str(idx),
                    "untested-public-api",
                    f"No tests reference {func_name}: " + ev,
                )
    elif ext == "go":
        for idx, content in enumerate(lines, start=1):
            if not GO_EXPORTED_FUNC_RE.search(content):
                continue
            m = re.search(r"^func ([A-Z][a-zA-Z0-9]*)", content)
            func_name = m.group(1) if m else ""
            test_file = f"{dirname}/{name_no_ext}_test.go"
            if os.path.isfile(test_file) and not _word_in_file(test_file, func_name):
                ev = content[:60]
                emit(
                    path,
                    str(idx),
                    "untested-public-api",
                    f"No tests reference {func_name}: " + ev,
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
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
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
