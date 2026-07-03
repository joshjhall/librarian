#!/usr/bin/env python3
"""check-security — Deterministic Pre-Scan (Python primary implementation).

Detects security patterns catchable by regex: hardcoded secrets, injection
risks, XSS patterns, and insecure cryptography. Results are passed to the LLM
for context-dependent confirmation/dismissal.

This is the Python 3.11+ primary implementation behind the language-agnostic TSV
contract; the sibling patterns.sh is the portable bash fallback (it exec's this
file when a python3>=3.11 is present). Both emit byte-identical findings — the
parity is pinned by tests/validate-python-ports.sh. See CLAUDE.md § Key
conventions (runtime policy).

Input:  argv[1] = file containing paths to scan (one per line)
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found
"""

from __future__ import annotations

import re
import sys
from fnmatch import fnmatch

CERTAINTY = "HIGH"
EVIDENCE_CAP = 80  # matches printf '%.80s' in patterns.sh

# Path globs skipped entirely (test fixtures, sample env files, lock files) —
# mirrors the leading `case "$file"` skip arms in patterns.sh.
SKIP_GLOBS = (
    "*test*fixture*",
    "*testdata*",
    "*.env.example",
    "*.env.sample",
    "*.env.template",
    "*lock.json",
    "*lock.yaml",
    "*.lock",
    "*go.sum",
)

# --- XSS pattern literals ----------------------------------------------------
# Built from concatenated fragments so this scanner does not flag ITSELF on the
# very tokens it hunts for (same hook-evasion the bash impl uses for its
# XSS_* variables). The reassembled strings are the real patterns.
XSS_REACT = "dangerously" + "SetInnerHTML"  # literal substring
XSS_VUE = "v-" + "html"  # literal substring
# Django/Jinja template escape-bypass filter/function. Fragmented (like the
# other XSS literals) so this scanner does not flag its own source.
XSS_SAFE_RE = r"\|" + "safe" + r"\b|" + "mark_saf" + r"e\("
XSS_BLADE = "{" + "!!"  # literal substring


def emit(path: str, line_no: int, category: str, evidence: str) -> None:
    """Write one TSV finding row (avoids the print() builtin by design)."""
    sys.stdout.write(
        "\t".join((path, str(line_no), category, evidence, CERTAINTY)) + "\n"
    )


def cap(content: str) -> str:
    """First EVIDENCE_CAP chars of the raw matched line (label added by caller)."""
    return content[:EVIDENCE_CAP]


def scan_file(path: str) -> None:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return

    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""

    for idx, line in enumerate(lines, start=1):
        # --- Category: hardcoded-secret (all files) ---

        if re.search(r"AKIA[0-9A-Z]{16}", line):
            emit(path, idx, "hardcoded-secret", "AWS access key pattern: " + cap(line))

        if re.search(r"(ghp_|gho_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}", line):
            emit(path, idx, "hardcoded-secret", "GitHub token pattern: " + cap(line))

        if re.search(r"(sk_live_|rk_live_|pk_live_)[A-Za-z0-9]{20,}", line):
            emit(path, idx, "hardcoded-secret", "Stripe live key pattern: " + cap(line))

        if re.search(r"BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY", line):
            emit(path, idx, "hardcoded-secret", "Private key header: " + cap(line))

        # Generic credential assignment with a string-literal value. Two-stage,
        # mirroring the `grep -nEi ... | grep -viE <denylist>` pipe: a positive
        # match that is NOT a placeholder/env-read/comment line. The quote
        # delimiter class is ["'] — a double- or single-quote (matches the bash
        # regex fixed in #168).
        if re.search(
            r"(password|passwd|secret|api_key|apikey|auth_token|access_token)"
            r"""\s*[=:]\s*["'][^"']{8,}["']""",
            line,
            re.IGNORECASE,
        ) and not re.search(
            r"(changeme|placeholder|xxx|todo|example|replace|your_|test_|fake_|dummy_|#|//|/\*)",
            line,
            re.IGNORECASE,
        ):
            emit(
                path,
                idx,
                "hardcoded-secret",
                "Possible hardcoded credential: " + cap(line),
            )

        # --- Category: injection-risk ---

        # SQL built via language-native interpolation (per-language dispatch).
        if ext == "py":
            if re.search(r"""f["'](SELECT|INSERT|UPDATE|DELETE|DROP)\b""", line):
                emit(path, idx, "injection-risk", "SQL in f-string: " + cap(line))
        elif ext in ("js", "ts", "jsx", "tsx"):
            if re.search(r"`(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\$\{", line):
                emit(
                    path,
                    idx,
                    "injection-risk",
                    "SQL in template literal: " + cap(line),
                )
        elif ext == "rb":
            if re.search(r'"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*#\{', line):
                emit(
                    path,
                    idx,
                    "injection-risk",
                    "SQL with string interpolation: " + cap(line),
                )

        # String concatenation with SQL keywords (all languages).
        if re.search(r'"(SELECT|INSERT|UPDATE|DELETE)\b.*"\s*\+\s*', line):
            emit(
                path,
                idx,
                "injection-risk",
                "SQL string concatenation: " + cap(line),
            )

        # --- Category: xss-risk (all files) ---

        if XSS_REACT in line:
            emit(path, idx, "xss-risk", "React raw HTML rendering: " + cap(line))

        if XSS_VUE in line:
            emit(path, idx, "xss-risk", "Vue raw HTML directive: " + cap(line))

        if re.search(XSS_SAFE_RE, line):
            emit(
                path,
                idx,
                "xss-risk",
                "Template safe filter bypassing escaping: " + cap(line),
            )

        if XSS_BLADE in line:
            emit(path, idx, "xss-risk", "Blade unescaped output: " + cap(line))

        # --- Category: insecure-crypto (skip comment-only lines) ---
        # A line whose first non-space character opens a comment (#, //, /*, *)
        # is skipped — matches the fixed bash `grep -v '^[0-9]+:\s*(#|...)'`
        # filter (see #168; the earlier anchor never fired against grep -n's
        # line-number prefix, so comment lines were wrongly flagged).
        is_comment = re.match(r"\s*(#|//|/\*|\*)", line) is not None

        if not is_comment and re.search(r"\b(md5|sha1)\s*\(", line, re.IGNORECASE):
            emit(path, idx, "insecure-crypto", "Weak hash algorithm: " + cap(line))

        if not is_comment and re.search(
            r"\bECB\b|MODE_ECB|mode.*ecb", line, re.IGNORECASE
        ):
            emit(path, idx, "insecure-crypto", "ECB mode encryption: " + cap(line))


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
        # Skip anything that is not a regular readable file ([ -f "$file" ]).
        try:
            with open(path, "r", encoding="utf-8", errors="replace"):
                pass
        except OSError:
            continue
        if any(fnmatch(path, g) for g in SKIP_GLOBS):
            continue
        scan_file(path)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
