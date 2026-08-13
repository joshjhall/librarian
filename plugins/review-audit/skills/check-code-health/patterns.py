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

Note on the shared bash regions: patterns.sh carries three `>>> shared:` blocks
(`is-test-file`, `debug-print-scan`, `debugger-scan`) kept byte-identical with
ship-issue/pre-review-gates.sh by tests/validate-shared-scanner-sync.sh. Those
blocks live in the BASH fallback; this file re-expresses the same logic in
Python, and the parity test guarantees it stays equivalent to the bash (and thus
to the shared copy). A further region, `scanner-pattern-line`, was retired from
this pair by #604 — the predicate now lives only in pre-review-gates.sh, whose
unanchored ai-slop arms are the sole place it earns its keep.

The debug detection is split into two families (#680), mirroring the bash:
prints (stdout — a CLI's actual output) and debuggers (never output). Both this
scanner and pre-review-gates.sh act on the distinction (#686): a project's
`.claude/pre-review.yml` may declare files under `stdout_is_output`, which
exempts the PRINT family only — a declared file's breakpoints still fire.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found
"""

from __future__ import annotations

import atexit
import os
import re
import shutil
import string
import subprocess
import sys
import tempfile
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


# --- declared `stdout_is_output` support (#686) ------------------------------
#
# A project declares, in its own .claude/pre-review.yml, the files whose
# print()/console.log IS the program's output rather than a debug leftover
# (#680). This is the PRIMARY runtime — patterns.sh exec's this file whenever a
# python3>=3.11 exists — so the behaviour has to live here, not only in the bash
# fallback.
#
# WHY SHELL OUT TO `git check-ignore` INSTEAD OF MATCHING IN PYTHON. The bash
# copy delegates matching to git, and tests/validate-python-ports.sh pins the two
# impls to byte-identical output. Reimplementing gitignore semantics here
# (`**`, negation, directory-only patterns, anchoring) would make parity a thing
# to maintain by hand, and any divergence is a silent wrong answer rather than an
# error. Using the same engine makes agreement structural. Precedent for the
# subprocess-to-git shape: check-docs-examples/patterns.py and
# check-docs-organization/patterns.py already do it.

_STDOUT_POLICY_LOADED = False
_PROJECT_ROOT = ""
_STDOUT_PATTERN_REPO = ""


def _read_yaml_list(key: str, path: str) -> list[str]:
    """The values of top-level list `key` in a flat YAML scalar list.

    The Python twin of the bash `shared:yaml-list-parser` region. Deliberately
    NOT a YAML library: the format is a flat list of scalars, the bash copy
    parses it without one, and adding a dependency here would put the two impls
    on different parsers — the one thing parity cannot absorb.

    Trailing whitespace comes off unconditionally, whitespace inside quotes is
    kept: the #684 rule, mirrored so a config resolves the same either side.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            raw = fh.read().splitlines()
    except OSError:
        return []

    out: list[str] = []
    in_section = False
    for line in raw:
        if line.startswith(key + ":"):
            in_section = True
            continue
        # Any other line starting in column 0 with a letter/underscore is the
        # NEXT top-level key, which ends this section.
        #
        # ASCII-only, matching the bash glob `[a-zA-Z_]*` exactly. NOT
        # `str.isalpha()`, which is Unicode-aware: `café:` in column 0 would end
        # the section in Python and not in bash, so the two runtimes would read
        # the same config differently. Narrow, but the parity contract's whole
        # value is that neither impl gets to be slightly different — and a
        # divergence here is a silent wrong answer, not an error.
        #
        # `line[:1]` is guarded against "" first: the empty string is a substring
        # of every string, so `"" in string.ascii_letters` is TRUE and a BLANK
        # line would end the section. bash's glob does not match an empty line,
        # and a blank line inside a list is ordinary YAML.
        first = line[:1]
        if first and (first in string.ascii_letters or first == "_"):
            in_section = False
            continue
        if not in_section:
            continue

        item = line
        unindented = item.lstrip()
        if unindented.startswith("-"):
            item = unindented[1:].lstrip()

        # One layer of surrounding quotes, each side independent.
        if item.startswith('"'):
            item = item[1:]
        elif item.startswith("'"):
            item = item[1:]
        item = item.rstrip()
        if item.endswith('"'):
            item = item[:-1]
        elif item.endswith("'"):
            item = item[:-1]

        if item:
            out.append(item)
    return out


def _cleanup_stdout_policy() -> None:
    """Remove the throwaway match repo. Registered with atexit the moment the
    repo is created — the bash copy's 'one cleanup branch per mktemp' rule, whose
    absence is silent (a stray /tmp dir, no error, no wrong output)."""
    if _STDOUT_PATTERN_REPO:
        shutil.rmtree(_STDOUT_PATTERN_REPO, ignore_errors=True)


def _load_stdout_policy() -> None:
    """Read `stdout_is_output` into a throwaway git repo, once per process."""
    global _STDOUT_POLICY_LOADED, _PROJECT_ROOT, _STDOUT_PATTERN_REPO
    if _STDOUT_POLICY_LOADED:
        return
    _STDOUT_POLICY_LOADED = True

    # The git subcommand and flags below are written as SPLIT string literals on
    # purpose. validate-scanner-category-parity.sh scrapes this file for
    # double-quoted lowercase-kebab literals and treats each as a declared
    # finding category; a hyphenated git flag matches that shape exactly and
    # would be reported as a phantom category present in the python impl and
    # missing from the bash one. Splitting the token keeps the flag out of the
    # scrape. Same workaround, same reason, as check-docs-examples/patterns.py.
    #
    # The gate reads raw text, so this comment must not spell those flags out
    # either — which is why they are described rather than quoted here.
    try:
        out = subprocess.run(
            ["git", "rev" + "-parse", "--show" + "-toplevel"],
            capture_output=True,
            text=True,
        )
        _PROJECT_ROOT = out.stdout.strip() or os.getcwd()
    except OSError:
        _PROJECT_ROOT = os.getcwd()

    config = os.path.join(_PROJECT_ROOT, ".claude", "pre-review.yml")
    if not os.path.isfile(config):
        return

    patterns = _read_yaml_list("stdout_is_output", config)
    # No declaration -> no repo -> the predicate is false for every file, and
    # this scanner behaves exactly as it did before #686.
    if not patterns:
        return

    repo = tempfile.mkdtemp()
    try:
        subprocess.run(
            ["git", "init", "-q", repo], capture_output=True, text=True, check=False
        )
        with open(
            os.path.join(repo, ".git", "info", "exclude"), "w", encoding="utf-8"
        ) as fh:
            fh.write("\n".join(patterns) + "\n")
    except OSError:
        shutil.rmtree(repo, ignore_errors=True)
        return

    _STDOUT_PATTERN_REPO = repo
    atexit.register(_cleanup_stdout_policy)


def _matches_declared_stdout(path: str) -> bool:
    """True when the project declared `path` under `stdout_is_output`.

    Always False when nothing was declared, so a repo with no config keeps the
    pre-#686 behaviour exactly.
    """
    _load_stdout_policy()
    if not _STDOUT_PATTERN_REPO:
        return False

    relpath = path
    if _PROJECT_ROOT and _PROJECT_ROOT != ".":
        prefix = _PROJECT_ROOT + os.sep
        if relpath.startswith(prefix):
            relpath = relpath[len(prefix) :]
    relpath = relpath.lstrip("/")

    try:
        res = subprocess.run(
            [
                "git",
                "-C",
                _STDOUT_PATTERN_REPO,
                "check" + "-ignore",
                "-q",
                "--no" + "-index",
                relpath,
            ],
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    return res.returncode == 0


def _scan_debug_print(path: str, idx: int, line: str, ext: str) -> None:
    """Emit debug-statement rows for the stdout-writing family.

    Mirrors the `>>> shared:debug-print-scan` bash region. These are what a CLI
    legitimately uses to produce its output, which is why a project may exempt
    them via `stdout_is_output` (#680/#686). The caller applies that exemption
    per FILE — see scan_file; this function itself is unconditional.

    No scanner-pattern-literal skip, matching the bash copies after #604: every
    pattern is `^\\s*`-anchored, so a scanner's own literal — always nested
    inside an indented grep call — can never match line-start. The old guard
    suppressed nothing real (measured: 0 rows) and silently dropped genuine
    debug statements whose ARGUMENT looked like a regex, e.g.
    `print(re.search(r"\\d+", data))`. Keep new patterns anchored.
    """
    if ext == "py":
        if re.search(r"^\s*print\(", line) and not re.search(
            r"(logging|logger|log\.)", line
        ):
            emit(path, idx, "debug-statement", "Debug print statement", line)
    elif ext in ("js", "ts", "jsx", "tsx", "mjs", "cjs"):
        if re.search(r"^\s*console\.(log|debug|warn|info|trace)\(", line):
            emit(path, idx, "debug-statement", "Console debug statement", line)
    elif ext == "go":
        if re.search(r"^\s*fmt\.Print(ln|f)?\(", line):
            emit(path, idx, "debug-statement", "Debug print statement", line)
    elif ext in ("java", "kt"):
        if re.search(r"^\s*System\.(out|err)\.print(ln)?\(", line):
            emit(path, idx, "debug-statement", "Debug print statement", line)


def _scan_debugger(path: str, idx: int, line: str, ext: str) -> None:
    """Emit debug-statement rows for the breakpoint family.

    Mirrors the `>>> shared:debugger-scan` bash region. NEVER exempted by any
    declaration: a breakpoint is never a program's output, so exempting one
    would be a real false negative (#680 AC3). Same anchoring rule as
    _scan_debug_print.
    """
    if ext == "py":
        if re.search(r"^\s*(breakpoint\(\)|import pdb|pdb\.set_trace)", line):
            emit(path, idx, "debug-statement", "Debugger statement", line)
    elif ext in ("js", "ts", "jsx", "tsx", "mjs", "cjs"):
        if re.search(r"^\s*debugger\s*;?\s*$", line):
            emit(path, idx, "debug-statement", "Debugger keyword", line)
    elif ext == "rb":
        if re.search(r"^\s*(binding\.pry|binding\.irb|byebug)\b", line):
            emit(path, idx, "debug-statement", "Ruby debugger", line)


def scan_file(path: str, lines: list[str]) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    test_file = is_test_file(path)
    # Resolved ONCE PER FILE, not per line (#686). The declaration is a property
    # of the file, and the predicate shells out to `git check-ignore` — evaluating
    # it inside the loop below would spawn one subprocess per line of every file
    # scanned. Hoisted here alongside test_file, which is per-file for the same
    # reason.
    stdout_declared = not test_file and _matches_declared_stdout(path)

    for idx, line in enumerate(lines, start=1):
        # --- Category: tech-debt-marker (all source files) ---
        if re.search(r"\b(TODO|FIXME|HACK|XXX|WORKAROUND)\b", line, re.IGNORECASE):
            emit(path, idx, "tech-debt-marker", "Tech debt marker", line)

        # --- Category: debug-statement (non-test files only) ---
        # Split into the same two families as the bash regions (#680); see the
        # module docstring. Called in this order — prints then debuggers — to
        # match the bash arms' emission order within a language.
        #
        # The print family is skipped for a declared file; the debugger family
        # is NOT (#680 AC3). Two separate statements, mirroring the bash
        # dispatcher: there is no control path on which the declaration reaches
        # the debugger call, which is the property AC3 asks for.
        if not test_file:
            if not stdout_declared:
                _scan_debug_print(path, idx, line, ext)
            _scan_debugger(path, idx, line, ext)

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
