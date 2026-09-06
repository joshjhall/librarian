#!/usr/bin/env python3
"""loop-make-it-right — Deterministic Pre-Scan (Python primary implementation).

Detects structural quality issues: long functions, deep nesting, and
single-character variable names outside loop counters.

Python 3.11+ primary implementation behind the language-agnostic TSV contract;
the sibling patterns.sh is the portable bash fallback (it exec's this file when a
python3>=3.11 is present). Both emit byte-identical findings — the parity is
pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key conventions.

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found

Thresholds are env-overridable (LOOP_MAX_FUNCTION_LINES, LOOP_MAX_NESTING_DEPTH),
matching the bash impl so the orchestrator's thresholds.yml values apply either
way.
"""

from __future__ import annotations

import os
import re
import sys

CERTAINTY = "HIGH"
EVIDENCE_CAP = 60  # long-function/nesting/name evidence uses printf '%.60s'

BRACE_EXTS = ("ts", "js", "tsx", "jsx", "go", "rs")

# Function-definition patterns.
PY_DEF_RE = re.compile(r"^\s*def \w+")
BRACE_DEF_RE = re.compile(
    r"^\s*(export\s+)?(async\s+)?function\s+\w+|^func\s+|^(pub\s+)?fn\s+"
)
# single-char-name (Python only): a leading-indented single letter assignment.
PY_SINGLE_ASSIGN_RE = re.compile(r"^\s+[a-zA-Z]\s*=")
PY_SINGLE_SKIP_RE = re.compile(r"^\s*(for|with)\s+[a-zA-Z]\s+in\b|_\s*=")
PY_VARNAME_RE = re.compile(r"^\s*([a-zA-Z])\s*=")

# Conventional single-char names never flagged (loop counters etc.).
SKIP_VARNAMES = {"i", "j", "k", "n", "x", "y", "_", "e", "f"}


def _int_env(name: str, default: int) -> int:
    """Read an integer env override, falling back to default on unset/empty/bad —
    mirrors bash `${VAR:-default}` followed by integer use."""
    val = os.environ.get(name, "")
    try:
        return int(val)
    except ValueError:
        return default


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


def _leading_ws_len(line: str) -> int:
    """Number of leading whitespace chars (awk RLENGTH of /^[[:space:]]+/)."""
    m = re.match(r"[ \t]+", line)
    return m.end() if m else 0


def scan_long_functions(path: str, lines: list[str], ext: str, max_lines: int) -> None:
    total = len(lines)
    if ext == "py":
        # Python: from `def`, count to the next line at same-or-lower indent.
        for idx, content in enumerate(lines, start=1):
            if not PY_DEF_RE.search(content):
                continue
            # indent = the column the first non-space character sits at, i.e.
            # the length of the leading-space run. That is the value the
            # `^.{0,indent}[^ ]` probe below wants: the extent ends at the first
            # following line whose non-space starts at the same column or lower.
            #
            # The `+ 1` this line used to carry was a real off-by-one (#932), not
            # a parity concession. It came from modelling the bash fallback's
            # `sed 's/[^ ].*//' | wc -c` INCLUDING a trailing newline -- but GNU
            # sed emits no newline for input that lacks one, so the fallback was
            # in fact returning the plain space count and the two impls disagreed
            # by one on any body indented exactly one column past its `def`.
            # (Measured on Linux: a def at indent 4 with a body at indent 5 fired
            # under bash and stayed silent under python.) The fallback now counts
            # the run in pure bash; both sides use the space count, which is also
            # the semantically correct probe width.
            stripped = re.sub(r"[^ ].*", "", content)
            indent = len(stripped)
            # end_line = first following line matching ^.\{0,indent\}[^ ]
            end_off = None
            pat = re.compile(r"^.{0," + str(indent) + r"}[^ ]")
            for off, ln in enumerate(lines[idx:], start=1):
                if pat.search(ln):
                    end_off = off
                    break
            func_lines = end_off if end_off is not None else (total - idx)
            if func_lines > max_lines:
                ev = content[:EVIDENCE_CAP]
                emit(
                    path,
                    idx,
                    "long-function",
                    f"Function {func_lines} lines (max {max_lines}): {ev}",
                )
    elif ext in BRACE_EXTS:
        # Brace languages: count from a definition to the next definition.
        for idx, content in enumerate(lines, start=1):
            if not BRACE_DEF_RE.search(content):
                continue
            next_off = None
            for off, ln in enumerate(lines[idx:], start=1):
                if BRACE_DEF_RE.search(ln):
                    next_off = off
                    break
            func_lines = next_off if next_off is not None else (total - idx)
            if func_lines > max_lines:
                ev = content[:EVIDENCE_CAP]
                emit(
                    path,
                    idx,
                    "long-function",
                    f"Function {func_lines} lines (max {max_lines}): {ev}",
                )


def scan_deep_nesting(path: str, lines: list[str], ext: str, max_depth: int) -> None:
    # Python: 4-space indent unit; brace langs: 2-space unit. Only lines that
    # begin with whitespace THEN a non-space are considered (awk guard).
    if ext == "py":
        unit = 4
    elif ext in BRACE_EXTS:
        unit = 2
    else:
        return
    for idx, line in enumerate(lines, start=1):
        if not re.match(r"[ \t]+[^ \t]", line):
            continue
        depth = _leading_ws_len(line) // unit
        if depth > max_depth:
            ev = line[:EVIDENCE_CAP]
            emit(
                path,
                idx,
                "deep-nesting",
                f"Nesting depth {depth} (max {max_depth}): {ev}",
            )


def scan_single_char_names(path: str, lines: list[str], ext: str) -> None:
    if ext != "py":
        return
    for idx, content in enumerate(lines, start=1):
        if not PY_SINGLE_ASSIGN_RE.search(content):
            continue
        if PY_SINGLE_SKIP_RE.search(content):
            continue
        m = PY_VARNAME_RE.search(content)
        if not m:  # pragma: no cover - unreachable: PY_SINGLE_ASSIGN_RE above
            # (`^\s+[a-zA-Z]\s*=`) guarantees PY_VARNAME_RE (`^\s*([a-zA-Z])\s*=`)
            # matches, so `not m` never occurs; defensive only (bash sed would
            # leave content unchanged, yielding a varname that matches no skip).
            continue
        varname = m.group(1)
        if varname in SKIP_VARNAMES:
            continue
        ev = content[:EVIDENCE_CAP]
        emit(
            path,
            idx,
            "single-char-name",
            f"Single-character variable '{varname}': {ev}",
        )


def scan_file(path: str, lines: list[str], max_lines: int, max_depth: int) -> None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    scan_long_functions(path, lines, ext, max_lines)
    scan_deep_nesting(path, lines, ext, max_depth)
    scan_single_char_names(path, lines, ext)


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

    max_lines = _int_env("LOOP_MAX_FUNCTION_LINES", 50)
    max_depth = _int_env("LOOP_MAX_NESTING_DEPTH", 4)

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
        if not path:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        scan_file(path, lines, max_lines, max_depth)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
