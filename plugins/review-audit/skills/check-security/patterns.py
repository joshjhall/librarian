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

import os
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


# --- the lexical model (ADR 0002 § 2, #622 Phase 1) --------------------------
# A SUBSET of the normative EXT_LANG / COMMENT_RE in
# check-decomposition/loc_engine.py. Deliberately NOT imported from there: that
# file is one half of a byte-identical pair pinned against ship-issue's copy, and
# adding a third consumer would make the pinning tripartite (ADR 0002 § 2). It is
# also not a new table in the #663 sense — tests/lint-language-table-sync.sh
# asserts this copy is a consistent SUBSET, so it may cover fewer extensions than
# the normative table but may never contradict it.
#
# Covers every extension this scanner dispatches on, plus rs. A language absent
# here does not resolve, and every LEXICAL-DEPENDENT detector below is skipped
# for its files — the ADR § 1 `—` state. Per ADR § 5 that is SILENT: an
# unsupported file emits no TSV row at all, never an `unsupported-language` one.
EXT_LANG = {
    "py": "py",
    "js": "js",
    "jsx": "js",
    "mjs": "js",
    "cjs": "js",
    "ts": "ts",
    "tsx": "ts",
    "rs": "rs",
    "go": "go",
    "rb": "rb",
    "sh": "sh",
    "bash": "sh",
    "java": "java",
    "kt": "java",
    "swift": "swift",
    # CONFIG FORMATS. Not source languages, and absent from the normative
    # EXT_LANG (which serves the decomposition lenses, where they are not units
    # of code) — so they are scanner-local additions, permitted because
    # lint-language-table-sync.sh checks SUBSET-consistency: a key the normative
    # table does not carry cannot contradict it.
    #
    # They are here because leaving them out is a SECURITY REGRESSION, caught in
    # review. Before the gating, the credential detector ran on every file; a
    # `password: "…"` in a docker-compose.yml or an application.properties was
    # flagged. Scoping the lexical model to source languages would silently stop
    # scanning exactly the file types where checked-in credentials most often
    # live — and ADR § 5 makes that silence total. All of these spell a line
    # comment with `#`.
    "yml": "conf",
    "yaml": "conf",
    "ini": "conf",
    "cfg": "conf",
    "conf": "conf",
    "toml": "conf",
    "properties": "conf",
    "env": "conf",
    # MAINSTREAM C-FAMILY LANGUAGES, for the same reason and by the same rule:
    # scanner-local keys, absent from the normative table so they cannot
    # contradict it, present because main DID scan them and dropping them is a
    # security regression (measured: a `$password = "…"` in .php and an `MD5(`
    # in .c both fired before this branch). All spell a line comment `//` with
    # `/* */` blocks — the model already written for js/ts/rs/go/java/swift.
    "php": "cfamily",
    "c": "cfamily",
    "h": "cfamily",
    "cc": "cfamily",
    "cpp": "cfamily",
    "hpp": "cfamily",
    "cs": "cfamily",
    "scala": "cfamily",
    "m": "cfamily",
    "mm": "cfamily",
    "dart": "cfamily",
    "groovy": "cfamily",
    "gradle": "cfamily",
    "v": "cfamily",
    "zig": "cfamily",
    "cr": "cfamily",
    # `#`-COMMENT LANGUAGES beyond py/sh/rb. Same rule, same reason. Grouped
    # under the existing `hash` family rather than given individual keys — the
    # lexical fact IS the comment marker, so languages that share one share an
    # entry.
    "pl": "hash",
    "pm": "hash",
    "r": "hash",
    "jl": "hash",
    "ex": "hash",
    "exs": "hash",
    "nim": "hash",
    "tcl": "hash",
    "zsh": "hash",
    "fish": "hash",
    "ps1": "hash",
    "psm1": "hash",
    "tf": "hash",
    "tfvars": "hash",
    # MISCELLANEOUS MARKERS — one family per distinct spelling.
    "lua": "dashdash",  # -- line comments (the ADR's motivating false positive)
    "sql": "dashdash",
    "hs": "dashdash",
    "elm": "dashdash",
    "vb": "quote",  # ' line comments
    "bas": "quote",
    "erl": "percent",  # % line comments
    "clj": "semicolon",  # ; line comments
    "asm": "semicolon",
    "bat": "rem",  # REM / :: line comments
    "vue": "html",  # <!-- --> plus the JS/CSS blocks inside
    "svelte": "html",
    "html": "html",
    "xml": "html",
    "pas": "brace",  # { } and (* *) comments
    # JSON has NO comment syntax at all, so no line can be a comment and the
    # never-matching pattern below is the honest model rather than a missing one.
    # It is modeled because a checked-in service-account key or npm token is
    # exactly the kind of credential this detector exists to catch.
    "json": "json",
}

# How each language opens a LINE comment. Anchored at line start (modulo
# indentation) on purpose: the #837 defect was an UNANCHORED substring test, so a
# `#` anywhere on the line — inside the secret value, or a trailing `# noqa` —
# suppressed a real finding. Matching loc_engine.COMMENT_RE's spellings exactly.
COMMENT_RE = {
    "py": re.compile(r"^[ \t]*#"),
    "sh": re.compile(r"^[ \t]*#"),
    "rb": re.compile(r"^[ \t]*#"),
    "conf": re.compile(r"^[ \t]*#"),
    "js": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "ts": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "rs": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "go": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "java": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "swift": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "cfamily": re.compile(r"^[ \t]*(?://|/\*|\*)"),
    "hash": re.compile(r"^[ \t]*#"),
    "dashdash": re.compile(r"^[ \t]*--"),
    "quote": re.compile(r"^[ \t]*'"),
    "percent": re.compile(r"^[ \t]*%"),
    "semicolon": re.compile(r"^[ \t]*;"),
    "rem": re.compile(r"^[ \t]*([Rr][Ee][Mm][ \t]|::)"),
    "html": re.compile(r"^[ \t]*(?:<!--|//|/\*|\*)"),
    "brace": re.compile(r"^[ \t]*(?:\{|\(\*)"),
    # JSON has no comment syntax, so NO line opens a comment. `(?!)` never
    # matches — the explicit "this language has no comments" model, distinct
    # from a missing entry (which would make lang resolve but is_comment fall
    # through to False for the wrong reason).
    "json": re.compile(r"(?!)"),
}


# EXTENSIONLESS FILES, dispatched by BASENAME. An extension-keyed table cannot
# reach these at all — `Dockerfile` has no extension to look up — so without this
# they resolve to the `—` state and lose every lexical-dependent detector.
#
# That is a real regression and a measured one: `ENV PASSWORD="…"` in a
# Dockerfile fired on main and went silent here. Dockerfiles are among the most
# common homes for a checked-in credential (`ENV`/`ARG` lines), so this is the
# same class as the config-format carve-out, reached by a route an
# extension-keyed probe is blind to BY CONSTRUCTION — which is exactly why it
# survived the 52-extension sweep that caught the others.
#
# All of these spell a line comment with `#`. Matched case-sensitively: the
# conventional spellings are capitalized, and a lowercase `makefile` is also
# accepted since GNU make honors it.
BASENAME_LANG = {
    "Dockerfile": "hash",
    "Containerfile": "hash",
    "Makefile": "hash",
    "makefile": "hash",
    "GNUmakefile": "hash",
    "Jenkinsfile": "hash",
    "Vagrantfile": "hash",
    "Procfile": "hash",
    "Rakefile": "hash",
    "Gemfile": "hash",
    "Brewfile": "hash",
    "Justfile": "hash",
    "justfile": "hash",
    "Caddyfile": "hash",
    "CMakeLists.txt": "hash",
    # DOTFILES. A leading-dot name defeats extension keying in a second, subtler
    # way than an extensionless one: `.npmrc`.rsplit(".") yields `npmrc` and
    # `.env.local` yields `local`, so both resolve to a WRONG key rather than an
    # empty one. Measured — all three below fired on main and went silent.
    # These are prime credential carriers (`.netrc` and `.npmrc` exist to hold
    # credentials), and all are `#`-comment formats.
    ".env": "hash",
    ".npmrc": "hash",
    ".netrc": "hash",
    ".yarnrc": "hash",
    ".pypirc": "hash",
    ".dockerignore": "hash",
    ".gitconfig": "hash",
    ".gitignore": "hash",
    ".editorconfig": "hash",
    ".bashrc": "hash",
    ".zshrc": "hash",
    ".profile": "hash",
    ".bash_profile": "hash",
    ".htaccess": "hash",  # Apache config — AuthUserFile and friends
    ".mailmap": "hash",
}

# Basename families whose SUFFIX varies: `.env.local`, `.env.production`,
# `Dockerfile.dev`, `Dockerfile.prod`, `Makefile.include`. Keyed on the leading
# component and checked after the exact-basename table.
#
# The suffix here names a VARIANT of the same artifact, by universal convention —
# a `Dockerfile.prod` is a Dockerfile. An earlier draft matched `.env.*` this way
# but excluded `Dockerfile.*`, on the reasoning that its suffix "names a different
# artifact". That was wrong, and inconsistent with the very next line of the same
# table: measured, `ENV PASSWORD="…"` in a `Dockerfile.prod` fired on main and
# went silent. If a future name genuinely does re-key on its suffix, it belongs
# in BASENAME_LANG as an exact entry, not here.
PREFIX_LANG = {
    ".env": "hash",
    "Dockerfile": "hash",
    "Containerfile": "hash",
    "Makefile": "hash",
    "makefile": "hash",
}

# SHEBANG interpreters -> language key. The fifth path shape (#858), and the only
# one that is not closable by enumeration: the set of extensionless script names
# (`run`, `deploy`, `entrypoint`, `bootstrap`) is UNBOUNDED, so no longer
# BASENAME_LANG table reaches it. The file's own first line is the evidence
# instead.
#
# Every value is an EXISTING key from the tables above — this shape adds no new
# language, so lint-language-table-sync's normative-subset rule is untouched and
# each resolved file inherits a comment model that is already fixture-pinned.
#
# `zsh`/`fish`/`perl` map to `hash` rather than `sh` because that is where their
# EXTENSIONS already map (`*.zsh`, `*.fish`, `*.pl`); routing the shebang
# elsewhere would make the same file resolve differently by name and by content.
#
# THE `sh` vs `hash` DISTINCTION IS CURRENTLY UNOBSERVABLE, and that is recorded
# rather than tested. COMMENT_RE spells `sh`, `hash`, `py` and `rb` identically
# (`^[ \t]*#`), and this scanner's only per-language detector (injection-risk)
# dispatches on the file EXTENSION, not on this key — so swapping zsh to `sh`
# changes no TSV row. Verified by mutation: the swap survives the full fixture
# suite. It is kept correct anyway because the keys are a claim about the
# language, the mapping is what a future per-language detector would read, and a
# deliberately-wrong-but-currently-invisible entry is how a real divergence
# arrives later. A fixture pinning it would be a test that cannot fail.
SHEBANG_LANG = {
    "sh": "sh",
    "bash": "sh",
    "dash": "sh",
    "ksh": "sh",
    "zsh": "hash",
    "fish": "hash",
    "python": "py",
    "ruby": "rb",
    "perl": "hash",
    "node": "js",
}

# Trailing version suffix on an interpreter name: `python3`, `python3.11`,
# `perl5`, `ruby2.7`. Stripped before the SHEBANG_LANG lookup so one entry per
# interpreter covers every installed spelling.
_SHEBANG_VERSION_RE = re.compile(r"[0-9.]+$")

# Cap on the shebang read. Linux itself truncates `#!` lines at 128 bytes
# (BINPRM_BUF_SIZE); this is generous next to that and still bounds the read on
# a newline-free binary.
_SHEBANG_MAX = 512


def _shebang_lang(path: str) -> str:
    """Language key from PATH's `#!` line, or "" when there is none to read.

    Called ONLY after all four name-based shapes miss, and only for a file with
    no extension — so an ordinary `app.py` never opens the file. The read is one
    line, and lang_of itself runs once per file, so the cost is bounded at one
    extra line-read per extensionless unmatched file.

    Both spellings resolve: `#!/bin/bash` (interpreter is the path) and
    `#!/usr/bin/env bash` (the interpreter is the SECOND token — an `env` path
    names the launcher, not the language).
    """
    # BOUNDED read. `readline()` on a file with no newline reads the WHOLE file,
    # and an extensionless path is exactly where a binary blob turns up (a
    # committed artifact, a compiled hook). A shebang line is short by
    # definition, so cap the read rather than trusting the input's shape; the
    # bash half's `read` builtin stops at the first newline for the same reason.
    # (In practice scan_file reads the file anyway, so this is not the dominant
    # cost -- measured 0.2s on a 20MB newline-free blob in both runtimes -- but
    # a resolver should not be the thing that pulls a large file into memory.)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            first = fh.readline(_SHEBANG_MAX)
    except OSError:
        return ""
    if not first.startswith("#!"):
        return ""
    tokens = first[2:].split()
    if not tokens:
        return ""
    interp = tokens[0].rsplit("/", 1)[-1]
    # `env` (and `env -S`) delegates: the real interpreter is the next token that
    # is not an option.
    if interp == "env":
        interp = ""
        for tok in tokens[1:]:
            if tok.startswith("-"):
                continue
            interp = tok.rsplit("/", 1)[-1]
            break
        if not interp:
            return ""
    interp = _SHEBANG_VERSION_RE.sub("", interp)
    return SHEBANG_LANG.get(interp, "")


def lang_of(path: str, ext: str) -> str:
    """Language key for PATH, or "" when this scanner has no lexical model.

    Extension first, then a BASENAME fallback for extensionless files. An empty
    return is the ADR § 1 `—` state and is the gate every lexical-dependent
    detector consults before running.

    Three shapes, in order, because a real path can defeat extension keying in
    three different ways:

      1. EXTENSION      `app.py`          -> the ordinary case
      2. EXACT BASENAME `Dockerfile`      -> no extension at all, so ext is ""
      3. PREFIX         `Dockerfile.prod` -> ext is `prod`, a WRONG key
                        `.npmrc`          -> ext is `npmrc`, also wrong
                        `.env.local`      -> ext is `local`, also wrong
      4. SHEBANG        `deploy`          -> no extension AND untabled name

    Shape 3 is the subtle one: a leading dot or a variant suffix yields a key
    that looks valid and resolves to nothing, which is indistinguishable from
    "unmodeled" unless you look for it.

    Shape 4 (#858) is the one that differs in KIND. The first three are closable
    by enumeration — a finite table of extensions, basenames, prefixes. The set
    of extensionless script names (`run`, `deploy`, `entrypoint`, `bootstrap`) is
    unbounded, so no longer table reaches it; the file's own `#!` line is the
    evidence instead, which is why this function reads content at all.

    A file with no extension, no tabled name, and NO recognizable shebang stays
    "" deliberately — see contract.md. There is no evidence of a language, and
    defaulting to `sh` would apply a `#` comment model to arbitrary data files,
    re-creating the language-blind false positives ADR 0002 exists to remove.
    """
    lang = EXT_LANG.get(ext, "")
    if lang:
        return lang
    base = path.rsplit("/", 1)[-1]
    lang = BASENAME_LANG.get(base, "")
    if lang:
        return lang
    for prefix, plang in PREFIX_LANG.items():
        if base.startswith(prefix + "."):
            return plang
    # Shape 4, last: gated on a BASENAME that carried no extension, so an
    # ordinary source file has already returned above and never pays for the
    # read.
    #
    # The gate is `"." not in base`, NOT `not ext`. The caller computes `ext`
    # from the whole PATH, so a file under a dotted directory (`.github/deploy`,
    # `node_modules/.bin/tool`) yields a non-empty `ext` of `github/deploy` — and
    # `not ext` would skip the read for exactly the extensionless scripts this
    # shape exists to reach. The bash half gates on the basename for the same
    # reason; a whole-path test there agrees with a whole-path test here, so
    # parity would have hidden the miss rather than caught it (#684).
    if "." not in base:
        return _shebang_lang(path)
    return ""


def is_comment(lang: str, line: str) -> bool:
    """True if LINE opens a comment in LANG. False for an unresolved LANG —
    callers must gate on lang_of() first, so a `—` file never reaches here."""
    rx = COMMENT_RE.get(lang)
    return rx is not None and rx.match(line) is not None


def scan_file(path: str) -> None:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:  # pragma: no cover — unreachable: main() already probed the
        # file for readability and `continue`d on OSError before calling
        # scan_file, so this re-open only fails on a TOCTOU race (file becomes
        # unreadable between the two opens). Kept as a defensive guard, matching
        # the bash fallback's own per-file read that returns empty on failure.
        return

    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    # Resolved ONCE PER FILE — the language is a property of the path, not of a
    # line. "" means this scanner has no lexical model for the file, which gates
    # every lexical-dependent detector below (ADR 0002 § 1, the `—` state).
    lang = lang_of(path, ext)

    for idx, line in enumerate(lines, start=1):
        # --- Category: hardcoded-secret ---
        # The four literal patterns below are LEXICAL-INDEPENDENT (ADR 0002 § 3)
        # and run on every file, gated on nothing: `AKIA[0-9A-Z]{16}` is a leaked
        # key wherever it appears, and a commented-out one is arguably MORE
        # interesting, not less.

        if re.search(r"AKIA[0-9A-Z]{16}", line):
            emit(path, idx, "hardcoded-secret", "AWS access key pattern: " + cap(line))

        if re.search(r"(ghp_|gho_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}", line):
            emit(path, idx, "hardcoded-secret", "GitHub token pattern: " + cap(line))

        if re.search(r"(sk_live_|rk_live_|pk_live_)[A-Za-z0-9]{20,}", line):
            emit(path, idx, "hardcoded-secret", "Stripe live key pattern: " + cap(line))

        if re.search(r"BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY", line):
            emit(path, idx, "hardcoded-secret", "Private key header: " + cap(line))

        # Generic credential assignment with a string-literal value.
        # LEXICAL-DEPENDENT (ADR 0002 § 3) — gated on the resolved language, and
        # skipped entirely for a file whose lexical model this scanner lacks.
        #
        # #837: the old denylist conflated two unrelated tests in ONE unanchored
        # substring match over the WHOLE line —
        #   (changeme|placeholder|...|#|//|/\*)
        # which failed in both directions:
        #   FALSE NEGATIVE  password = "Str0ng#Pass#Value"   (# inside the value)
        #   FALSE NEGATIVE  password = "realsecret123"  # noqa  (trailing comment)
        #   FALSE POSITIVE  -- password = "x"   in .lua/.sql (`--` not modeled)
        # A false-clean in a security scanner, so the two tests are now separate:
        #   1. the COMMENT test is line-start anchored and per-language (above);
        #   2. the PLACEHOLDER test matches only the captured VALUE, never the
        #      whole line, so a `#` outside the value can no longer suppress.
        if lang and not is_comment(lang, line):
            m = re.search(
                r"(password|passwd|secret|api_key|apikey|auth_token|access_token)"
                r"""\s*[=:]\s*["']([^"']{8,})["']""",
                line,
                re.IGNORECASE,
            )
            if m and not re.search(
                r"(changeme|placeholder|xxx|todo|example|replace|your_|test_|fake_|dummy_)",
                m.group(2),
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
        elif ext == "rs":
            # Rust builds SQL with format!-family interpolation ({} holes) or by
            # push_str onto a String. Both are the idiomatic spelling of the same
            # unsanitized-concatenation defect the other arms catch (#838).
            #
            # TWO patterns, because the macros differ in ARGUMENT POSITION and a
            # single alternation cannot cover both: `format!` takes the format
            # string FIRST, while `write!`/`writeln!` take the `Write`
            # destination first and the format string SECOND. Folding them into
            # one `(format!|write!|writeln!)\s*\(\s*"` alternation makes the
            # write!/writeln! branches dead — no valid call has its format
            # string in argument one.
            if re.search(
                r'format!\s*\(\s*"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\{',
                line,
            ):
                emit(
                    path,
                    idx,
                    "injection-risk",
                    "SQL in format! interpolation: " + cap(line),
                )
            # The destination is skipped with `.*` rather than `[^,]+`: a
            # destination expression may itself contain a comma
            # (`write!(conn.buffer(a, b), "SELECT …", id)`), and a
            # comma-free-argument class stops at the FIRST comma, never reaching
            # the format string. Anchoring on the quoted SQL keyword is what
            # actually identifies the argument, so let `.*` reach it.
            if re.search(
                r'(write|writeln)!\s*\(.*,\s*"(SELECT|INSERT|UPDATE|DELETE|DROP)\b.*\{',
                line,
            ):
                emit(
                    path,
                    idx,
                    "injection-risk",
                    "SQL in write! interpolation: " + cap(line),
                )
            if re.search(
                r'push_str\s*\(\s*&?(format!\s*\(\s*)?"(SELECT|INSERT|UPDATE|DELETE|DROP)\b',
                line,
            ):
                emit(
                    path,
                    idx,
                    "injection-risk",
                    "SQL appended to String: " + cap(line),
                )

        # String concatenation with SQL keywords. LEXICAL-DEPENDENT (ADR 0002
        # § 3) — it reasons about string-literal form, so it is gated on the
        # resolved language and skipped on a comment line.
        if (
            lang
            and not is_comment(lang, line)
            and re.search(r'"(SELECT|INSERT|UPDATE|DELETE)\b.*"\s*\+\s*', line)
        ):
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

        # --- Category: insecure-crypto (skip comment lines) ---
        # LEXICAL-DEPENDENT (ADR 0002 § 3). This detector always ATTEMPTED to
        # consult a comment model, but the model was hardcoded C-family
        # (`#|//|/\*|\*`) and applied to every file regardless of language — so a
        # `--` comment in .lua/.sql was scanned as code. It now consults the
        # language's own model and does not run at all on an unresolved one.
        if lang and not is_comment(lang, line):
            if re.search(r"\b(md5|sha1)\s*\(", line, re.IGNORECASE):
                emit(path, idx, "insecure-crypto", "Weak hash algorithm: " + cap(line))

            if re.search(r"\bECB\b|MODE_ECB|mode.*ecb", line, re.IGNORECASE):
                emit(path, idx, "insecure-crypto", "ECB mode encryption: " + cap(line))


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
