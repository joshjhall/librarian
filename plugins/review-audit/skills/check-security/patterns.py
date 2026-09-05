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

# --- OWASP detector literals (#707) ------------------------------------------
# FRAGMENTED FOR THE SAME REASON AS THE XSS LITERALS ABOVE, and here it is not
# hypothetical: check-security's own owasp-coverage.yml documents these detectors
# in prose, `.yml` IS a modeled language, and the crypto arm was measured firing
# inside a .yml. A contiguous "verify=False" in this file (or in that map) would
# make the scanner report itself. Every literal below is therefore assembled from
# pieces that never appear contiguously in the source.
#
# The inverse trap is equally real: a FIXTURE written escaped so it cannot
# self-match also cannot be matched by the detector, and passes with AND without
# the fix. Fixtures must carry the real contiguous token.
#
# TIER. All seven are single-line-evident — the line IS the finding, with no data
# flow to reconstruct — so they ship at the module-level CERTAINTY (HIGH). The
# three taint-requiring detectors (#707 also listed path-traversal, ssrf,
# open-redirect) are deliberately ABSENT: measured over a 753-file corpus they
# produced 0 true positives in 8 hits (all `argv`-derived, request-derived = 0),
# which supports no tier at all. They are recorded as `gap:` entries in
# owasp-coverage.yml with that measurement, per contract.md's rule that a
# detector whose measured hit rate cannot support its tier does not ship.

# command-injection. Shapes reused from dev-core's loop-make-it-secure
# DANGER_FN_RE so the two scanners cannot drift into different definitions of
# the same defect.
CMD_SHELL_TRUE = r"subprocess\.[a-z_]+\s*\([^)]*shell\s*=\s*" + "Tru" + "e"
CMD_OS_SYSTEM = r"\bos\." + "syste" + r"m\s*\("
CMD_CHILD_EXEC = r"child_process\." + "exe" + r"c\s*\("
# eval/exec fire only on a NON-LITERAL argument: `eval("1+1")` is benign, while
# `eval(user_input)` / `eval("x" + s)` is the defect. A bare eval( match would
# fire on every dynamic-evaluation call and on any file merely naming it.
#
# The LEFT BOUNDARY is load-bearing and cost a real bug during development:
# `\b` alone still matches the `exec` inside `child_process.exec(`, so the JS
# command-injection fixture double-fired. `(?<![\w.])` additionally refuses a
# preceding dot, which is what distinguishes a bare `exec(...)` from any
# `<obj>.exec(...)` member call. Same class of defect as a bare `open(` matching
# inside `urlopen(` — measured on this repo while sizing the taint detectors.
CMD_EVAL_NONLITERAL = (
    r"(?<![\w.])(" + "eva" + "l|" + "exe" + r"c)\s*\(\s*[^\"')\s][^)]*\)"
)

# insecure-deserialization. yaml.load is unsafe only WITHOUT an explicit
# Loader= — the two-stage shape dev-core's UNSAFE_DESERIALIZE_RE/
# LOADER_EXCLUDE_RE pair established in #183, so yaml.safe_load and an explicit
# SafeLoader both stay silent.
DESERIALIZE_RE = (
    r"\b("
    + "pickl"
    + r"e\.loads?\s*\("
    + r"|"
    + "yaml\\.loa"
    + r"d\s*\("
    + r"|"
    + "marshal\\.loa"
    + r"ds?\s*\("
    + r"|"
    + "Marshal\\.loa"
    + r"d\s*\("
    + r"|"
    + "readObjec"
    + r"t\s*\("
    + r"|"
    + "unserializ"
    + r"e\s*\("
    + r")"
)
DESERIALIZE_SAFE_RE = r"(Loader\s*=|safe_load)"

# weak-randomness. A non-CSPRNG is only a FINDING when it feeds a security
# value; `Math.random()` picking a UI jitter is fine. The co-occurrence guard on
# the same line is what earns the HIGH tier here.
WEAK_RANDOM_FN = r"(Math\.random\s*\(\)|random\.random\s*\(\)|\brand\s*\(\))"
WEAK_RANDOM_CTX = r"(token|nonce|salt|session|secret|password|\bkey\b|iv\b)"

# tls-verification-disabled.
TLS_DISABLED_RE = (
    r"("
    + "verif"
    + r"y\s*=\s*"
    + "Fals"
    + "e"
    + r"|"
    + "rejectUnauthorize"
    + r"d\s*:\s*"
    + "fals"
    + "e"
    + r"|"
    + "InsecureSkipVerif"
    + r"y\s*:\s*"
    + "tru"
    + "e"
    + r"|"
    + "NODE_TLS_REJECT_UNAUTHORIZE"
    + r"D\s*=\s*.?0"
    + r")"
)

# permissive-cors. A wildcard origin, or an origin reflector that trusts every
# caller.
CORS_RE = (
    r"("
    + "Access-Control-Allow-Origi"
    + r"n\s*:?\s*[\"']?\s*\*"
    + r"|"
    + "origi"
    + r"n\s*:\s*"
    + "tru"
    + "e"
    + r")"
)

# jwt-unverified. alg=none disables the signature outright; a decode call with
# verification explicitly switched off does the same thing by argument.
JWT_RE = (
    r"("
    + "al"
    + r"g[\"']?\s*:\s*[\"']?"
    + "non"
    + "e"
    + r"|"
    + "jwt\\.decod"
    + r"e\s*\([^)]*"
    + "verif"
    + r"y\s*=\s*"
    + "Fals"
    + "e"
    + r"|"
    + "jwt\\.decod"
    + r"e\s*\([^)]*"
    + "verif"
    + r"y\s*:\s*"
    + "fals"
    + "e"
    + r")"
)

# xxe-risk — an XML parser with external entities or DTD loading left enabled.
#
# The `-risk` suffix is REQUIRED, not stylistic (it mirrors xss-risk /
# injection-risk). Both category gates extract slugs with a regex that mandates
# an interior hyphen — `"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"` in
# validate-owasp-coverage.sh and validate-scanner-category-parity.sh — because a
# single-word pattern would also match every bare language code and quoted word
# in these files, turning them into phantom categories. A bare "xxe" is
# therefore INVISIBLE to both gates: the coverage map would claim a prescan id
# no scanner appears to emit, and the parity gate would not police it at all.
# Caught by validate-owasp-coverage.sh rule 2a while wiring this detector up.
XXE_RE = (
    r"("
    + "resolve_entitie"
    + r"s\s*=\s*"
    + "Tru"
    + "e"
    + r"|"
    + "libxml_disable_entity_loade"
    + r"r\s*\(\s*"
    + "fals"
    + "e"
    + r"|"
    + "XMLConstant"
    + "s"
    + r")"
)


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
#
# CHANGING THIS VALUE NEEDS A RE-PROBE, and the bash half must move with it
# (`head -c 512` in patterns.sh's shebang_lang). The two caps count differently
# -- this one is a CHARACTER limit under text-mode decoding, bash's is a BYTE
# limit -- so a multi-byte character straddling the boundary is where they could
# diverge. Measured at 512 with a UTF-8 `é` across byte 512: both runtimes stay
# silent, because the interpreter lands past the cap either way, so the
# difference is unobservable through the TSV and is deliberately not fixture-
# pinned (a test for it could not fail). That conclusion is tied to THIS value;
# re-probe rather than assume it survives a change. The boundary fixture that IS
# pinned lives in tests/validate-python-ports.sh and
# tests/validate-source-detectors.sh (`pastcap`).
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
    # definition, so cap the read rather than trusting the input's shape.
    #
    # The bash half caps the SAME way, with `head -c 512` ahead of its `read`.
    # An earlier draft of this comment claimed bash needed no cap because its
    # `read` builtin "stops at the first newline" -- that is true only when a
    # newline exists: measured, `IFS= read -r` on a 20MB newline-free file read
    # all 20,000,020 bytes into the variable. The comment asserted a safety
    # property the code did not have, which is the more dangerous half of the
    # bug (it tells the next reader not to look). Both runtimes are now capped
    # for real, and the caps must move together.
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

    FOUR dispatch steps, in order, covering the five path shapes contract.md
    tabulates -- step 3 handles two of them (dotfile and suffixed variant),
    since both are a leading-component prefix match:

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
            # EVERY match on the line, not just the first (#860). Two independent
            # defects were closed here; both emitted nothing, in BOTH runtimes,
            # so validate-python-ports.sh was green throughout (the
            # parity-gate-hides-shared-defect shape — same-output is not
            # same-intent):
            #
            #   1. FIRST-MATCH-ONLY. `re.search` returns one match, so a leading
            #      PLACEHOLDER suppressed the whole line and a real secret
            #      sharing it was never reported:
            #        password = "changeme"; api_key = "realsecret1"
            #      `finditer` walks them all.
            #
            #   2. QUOTED KEYS NEVER MATCHED. The key had to be followed
            #      IMMEDIATELY by whitespace/`=`/`:`, so a JSON or JS quoted key
            #      did not match at all — placeholder or not:
            #        {"api_key": "realsecretvalue123"}     <- silent on its own
            #      The `["']?` below accepts the closing quote. This, not (1), is
            #      what silenced #860's headline repro; `finditer` alone would
            #      have left it silent. Measured safe: zero new rows across all
            #      854 tracked files.
            #
            # ONE ROW PER LINE, and the evidence NAMES EVERY REAL SECRET. The TSV
            # is keyed file/line/category, so two rows would share a key. But
            # naming only the first match would re-create this very bug in
            # miniature — the line is flagged while the second secret is
            # invisible — and the 80-char evidence cap can truncate the later
            # secret off the quoted line entirely, so the key list is the only
            # thing that keeps it visible.
            keys = [
                m.group(1)
                for m in re.finditer(
                    r"(password|passwd|secret|api_key|apikey|auth_token|access_token)"
                    r"""["']?\s*[=:]\s*["']([^"']{8,})["']""",
                    line,
                    re.IGNORECASE,
                )
                # The placeholder test stays VALUE-scoped (#837) — never the
                # whole line — so a `#` or a placeholder word elsewhere on the
                # line cannot suppress. It is applied PER MATCH so one
                # placeholder cannot speak for its neighbours.
                if not re.search(
                    r"(changeme|placeholder|xxx|todo|example|replace|your_|test_|fake_|dummy_)",
                    m.group(2),
                    re.IGNORECASE,
                )
            ]
            if keys:
                emit(
                    path,
                    idx,
                    "hardcoded-secret",
                    "Possible hardcoded credential ("
                    + ", ".join(keys)
                    + "): "
                    + cap(line),
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

        # --- OWASP detectors (#707) ---
        # All LEXICAL-DEPENDENT (ADR 0002 § 3): each reasons about code, so a
        # commented-out `verify=False` or a prose line describing `pickle.loads`
        # is not a finding. This gating is also what keeps the scanner from
        # flagging its own documentation — check-security/owasp-coverage.yml
        # describes these very detectors, and `.yml` is a modeled language.
        if lang and not is_comment(lang, line):
            # command-injection
            if re.search(CMD_SHELL_TRUE, line):
                emit(
                    path,
                    idx,
                    "command-injection",
                    "Subprocess with shell=True: " + cap(line),
                )

            if re.search(CMD_OS_SYSTEM, line):
                emit(
                    path,
                    idx,
                    "command-injection",
                    "Shell command execution: " + cap(line),
                )

            if re.search(CMD_CHILD_EXEC, line):
                emit(
                    path,
                    idx,
                    "command-injection",
                    "Unsanitized child process exec: " + cap(line),
                )

            if re.search(CMD_EVAL_NONLITERAL, line):
                emit(
                    path,
                    idx,
                    "command-injection",
                    "Dynamic evaluation of a non-literal: " + cap(line),
                )

            # insecure-deserialization — two-stage: a positive match that an
            # explicit safe loader does NOT excuse.
            if re.search(DESERIALIZE_RE, line) and not re.search(
                DESERIALIZE_SAFE_RE, line
            ):
                emit(
                    path,
                    idx,
                    "insecure-deserialization",
                    "Unsafe deserialization of untrusted data: " + cap(line),
                )

            # weak-randomness — the security-context co-occurrence is required.
            if re.search(WEAK_RANDOM_FN, line) and re.search(
                WEAK_RANDOM_CTX, line, re.IGNORECASE
            ):
                emit(
                    path,
                    idx,
                    "weak-randomness",
                    "Non-CSPRNG used for a security value: " + cap(line),
                )

            # tls-verification-disabled. The JWT exclusion is deliberate: a bare
            # `verify=False` is the same token in both taxonomies, but on a
            # `jwt.decode(...)` line it disables a SIGNATURE check, not a TLS
            # certificate check. Without this, one line emitted two findings and
            # the TLS one named the wrong defect, sending a reader to the wrong
            # fix. The jwt-unverified arm below still reports it.
            if re.search(TLS_DISABLED_RE, line) and not re.search(JWT_RE, line):
                emit(
                    path,
                    idx,
                    "tls-verification-disabled",
                    "TLS certificate verification disabled: " + cap(line),
                )

            if re.search(CORS_RE, line):
                emit(
                    path,
                    idx,
                    "permissive-cors",
                    "Permissive CORS policy: " + cap(line),
                )

            if re.search(JWT_RE, line):
                emit(
                    path,
                    idx,
                    "jwt-unverified",
                    "JWT signature not verified: " + cap(line),
                )

            if re.search(XXE_RE, line):
                emit(
                    path,
                    idx,
                    "xxe-risk",
                    "XML parser with external entities enabled: " + cap(line),
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
