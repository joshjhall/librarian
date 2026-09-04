#!/usr/bin/env bash
# Scanner language-table consistency (#622 Phase 0, ADR 0002).
#
# The four check-* pre-scan scanners each dispatch on a file extension, and each
# carries its own idea of which extension is which language. ADR 0002 names ONE
# normative spelling of those lexical facts — EXT_LANG and COMMENT_RE in
# check-decomposition/loc_engine.py — and makes every other copy a SUBSET of it:
#
#   A scanner may cover FEWER extensions than the normative table. It may never
#   CONTRADICT it: an extension it dispatches on must map to the same language
#   key, and a comment marker it uses for a language must match.
#
# Subset-consistency rather than byte-identity is the point. Byte-identity would
# force every scanner to carry every language (check-lifecycle models 4, the
# docs scanner 8, and both are correct). A free-for-all permits exactly the drift
# ADR 0002 was written to stop — a dozen independent spellings of "`.mjs` is
# JavaScript", one of which will eventually disagree.
#
# WHY STRUCTURAL AND NOT BEHAVIORAL. Same argument as
# lint-scanner-case-dispatch.sh, which this gate is modelled on: the defect is
# silent (a scan just reports differently), it is per-arm, and it spreads by
# copy — a new scanner is written by copying a neighbour. A fixture corpus can
# only cover the languages it happens to contain; the source can be checked whole.
#
# WHAT THIS GATE ASSERTS
#
#   1. ANTI-VACUITY: the normative EXT_LANG was found and is populated.
#   2. ANTI-VACUITY: all four `## Language Support` matrices resolve and are
#      non-empty. extract_contract fails loud on a missing or duplicated id, so
#      a deleted marker aborts rather than silently passing an empty region.
#   3. NO CONTRADICTION: every extension a scanner dispatches on maps to the same
#      language key as the normative table. Extensions ABSENT from EXT_LANG are
#      silent here — the stricter "every dispatched extension must be covered"
#      form is Phase 1 work, because satisfying it today means extending
#      EXT_LANG, which is a BEHAVIOR change to check-decomposition (files with
#      those extensions would start being segmented).
#   4. MATRIX <-> SOURCE: every matrix CELL marked `M` has a dispatch arm in
#      BOTH runtimes for that cell's COLUMN; every cell marked `—` has one in
#      neither.
#   5. ANTI-VACUITY: every column binding resolves to at least one arm per
#      runtime.
#   6. Every column carrying an `M` cell has a binding at all.
#
# Assertion 4 is the load-bearing one. It converts each future phase's
# dual-runtime obligation from "remember to do both" into a gate — and it is the
# shape of check that would have caught #836, where check-lifecycle's bash half
# silently diverged from its Python twin.
#
# THE GRANULARITY OF ASSERTION 4 IS PER-CELL (#847). It was per-LANGUAGE through
# Phase 0, which was strictly weaker than the matrices it checked: `have_py`/
# `have_sh` unioned every extension dispatched anywhere in a file, and
# `parse_matrix` OR-ed a row across its columns. A wrong cell in one column
# therefore passed whenever any OTHER column had an arm for that extension —
# invisible exactly where the matrices are ragged on purpose (check-code-health's
# three dispatch chains disagree about `rb` and about `.mjs`/`.cjs`).
#
# What makes per-cell possible is BINDINGS below: an explicit map from each
# matrix column to the source region backing it, in both runtimes. The three
# binding kinds and why the map is hand-written rather than inferred are
# documented there.
#
# Two consequences worth knowing before editing this gate:
#
#   - A cell's parenthetical narrowing ("M (js/jsx only)") is now ENFORCED, not
#     prose. Under a row-level check there was no per-cell state for it to
#     qualify; per-cell it reads as `M` for the extensions it names and `—` for
#     the rest of the row.
#   - An `M` cell in a column with no binding is reported (assertion 6) rather
#     than skipped, so a new modeled column cannot go quietly unchecked.
#   - A `tag` binding matches the category literal only OUTSIDE comments. A tag
#     named in a comment is not an emission, and treating it as one would prove
#     coverage an arm does not have — silencing the MISMATCH this gate exists to
#     raise. Pinned by tests/fixtures/language-table/tag-in-comment/.
#
# STILL NOT CHECKED: `L` cells. They assert both the absence of a detector and
# the presence of correct lexical gating, and that gating does not exist until
# Phase 1 (#838). ADR 0002 § Consequences carries this.
#
# Assertion 3 also walks the byte-identical ext->lang `case` blocks in
# check-decomposition/patterns.sh and ship-issue/sizing.sh, like any other
# dispatch site. Those two blocks were pinned by nothing when this gate was
# written; since #844 they sit in a `>>> shared:lang-table` region compared
# byte-for-byte by tests/validate-shared-scanner-sync.sh.
#
# The two gates remain COMPLEMENTARY, not redundant, and neither subsumes the
# other. Byte-identity pins the two copies to EACH OTHER: it catches an
# extension added to one copy only, which subset-consistency here permits and
# so cannot see. But a defect present in BOTH copies passes an equality check by
# construction — so assertion 3 is what pins each copy against the NORMATIVE
# EXT_LANG, which byte-identity cannot do.
#
# Pure bash + coreutils + python3. No network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Scanner language-table consistency (#622)"

# Overridable so the negative fixtures can point the gate at a synthetic tree.
# Defaults to the real repo.
LANG_TABLE_ROOT="${LANG_TABLE_ROOT:-$REPO_ROOT}"

# This gate parses Python source and markdown tables with python3 (both grammars
# are beyond a portable grep). A missing runtime is an UNAVAILABLE LINTER, so it
# exits the reserved 77 sentinel rather than 0 — run-all.sh renders 77 as
# "[SKIP] ... did not run", because a silent skip is indistinguishable from a
# pass and is how a gate sits inert unnoticed (#538, #571).
if ! command -v python3 >/dev/null 2>&1; then
    skip_test "python3 not available (language-table consistency not checked)"
    generate_report
    exit 77
fi

# The analyzer prints one finding per line, each prefixed by a tag the tests
# below filter on. Run once; every assertion reads this one report, so the tree
# is walked a single time.
#
#   NORMATIVE <count>            — size of the normative EXT_LANG
#   MATRIX <skill> <count>       — CELLS parsed out of one contract matrix
#   NOMATRIX <skill>             — assertion 2 violation
#   CONTRADICTION <detail>       — assertion 3 violation
#   MISMATCH <detail>            — assertion 4 violation
#   VACUOUS <detail>             — assertion 5 violation (a binding matched no arm)
#   UNBOUND <detail>             — assertion 6 violation (an M cell with no binding)
LANG_REPORT="$(
    command python3 - "$LANG_TABLE_ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
PLUGINS = os.path.join(ROOT, "plugins")
SKILLS = os.path.join(PLUGINS, "review-audit", "skills")

# The four scanners ADR 0002 governs. Explicit and ordered, not a glob: a fifth
# check-* skill is NOT automatically in scope (it may legitimately have no
# language dispatch at all), so enrolling one is a deliberate edit here — same
# reasoning as tests/lib/fragments.sh and the workflow.js fragment manifests.
GOVERNED = (
    "check-security",
    "check-code-health",
    "check-lifecycle",
    "check-docs-missing-api",
)

# --- the column -> source-region binding map (#847) --------------------------
# A matrix COLUMN names one detector family; a scanner file holds several. This
# map says, per scanner, which source region backs each column — the thing that
# makes assertion 4 per-CELL rather than per-language.
#
# EXPLICIT AND HAND-MAINTAINED, never inferred from the column header. Same
# reasoning as GOVERNED above and the tests/lib/fragments.sh manifests: a header
# that happens to match a category tag is a coincidence this gate must not rely
# on. check-docs-missing-api proves the point — two of its three columns
# ("public-symbol form", "doc marker") are PROSE describing the syntax, not
# detector families at all.
#
# Three binding kinds:
#
#   ("tag", "<category>")   arms whose body emits that category-tag literal.
#                           The common case: the column header IS the tag.
#   ("fn", (py_fn, sh_fn))  arms inside the named function in each runtime.
#                           Needed when two columns share ONE tag — the only
#                           case is check-code-health's debug-print vs debugger,
#                           which both emit "debug-statement" (#680 split them
#                           into two families but one category).
#   ("file", None)          the whole-file union. Correct only for a scanner
#                           with ONE modeled column, where per-file already IS
#                           per-category. check-docs-missing-api's Python half
#                           emits no literal tag, so tag-binding cannot be the
#                           universal mechanism.
#
# A column absent from this map is NOT checked per-cell. That is deliberate for
# columns with no `M` cell anywhere — `L`-only columns (tech-debt-marker,
# hardcoded-secret, xss-risk, insecure-crypto) assert lexical gating that does
# not exist until Phase 1, and `—`-only columns assert nothing. An `M` cell in
# an UNBOUND column is reported as a defect (UNBOUND below) rather than passed
# over, so adding a modeled column without a binding fails loudly.
BINDINGS = {
    "check-security": {
        "injection-risk": ("tag", "injection-risk"),
        # `secret-literal` and `credential-assignment` (the #838 split of
        # hardcoded-secret) are deliberately UNBOUND: every cell in both columns
        # is `L`, and an L-only column is not checked per-cell — see the comment
        # above. They would also be unbindable by tag, since both families emit
        # the same "hardcoded-secret" literal. If either ever gains an `M` cell,
        # assertion 6 reports it UNBOUND and a ("fn", …) binding is needed then.
    },
    "check-code-health": {
        "debug-print": ("fn", ("_scan_debug_print", "scan_debug_prints")),
        "debugger": ("fn", ("_scan_debugger", "scan_debugger_statements")),
        "empty-handler": ("tag", "empty-handler"),
    },
    "check-lifecycle": {
        "unreaped-subprocess": ("tag", "unreaped-subprocess"),
        "terminate-without-kill": ("tag", "terminate-without-kill"),
        "unclosed-handle": ("tag", "unclosed-handle"),
        "unpaired-listener": ("tag", "unpaired-listener"),
    },
    "check-docs-missing-api": {
        "undocumented-public-api": ("file", None),
    },
}


def strip_comments(body):
    """Drop `#` and `//` comments from an arm body — whole-line AND trailing.

    Trailing comments are stripped too, and that is not thoroughness for its own
    sake. An earlier version kept them, on the reasoning that a line with a
    trailing comment "already carries the emit that makes it a true match". That
    is false whenever the comment names a DIFFERENT category than the code emits:

        emit(path, idx, "unreaped-subprocess", ...)  # see also "unclosed-handle"

    keeps `"unclosed-handle"` in the searched text and proves coverage the arm
    does not have — the exact false-coverage failure this stripping exists to
    close, reintroduced by the fix for it. Measured, not reasoned about.

    Quote-aware rather than a plain `#`/`//` find, because a `#` INSIDE a string
    literal is code: Ruby interpolation (`"...#{x}"`) and any regex containing
    `#` or `//` would otherwise truncate the line and lose a real emit — turning
    a false positive into a false negative, which is the worse direction.
    """
    kept = []
    for line in body.splitlines():
        quote = None
        cut = None
        i = 0
        while i < len(line):
            ch = line[i]
            if quote:
                if ch == "\\":
                    i += 2
                    continue
                if ch == quote:
                    quote = None
            elif ch in ("'", '"'):
                quote = ch
            elif ch == "#" or line.startswith("//", i):
                cut = i
                break
            i += 1
        kept.append(line if cut is None else line[:cut])
    return "\n".join(kept)


def bound_exts(kind, key, arms, runtime):
    """Extensions dispatched by the region this binding names.

    `runtime` is 0 for Python and 1 for bash — it selects from an `fn` binding's
    (py_fn, sh_fn) pair.
    """
    if kind == "file":
        return arm_exts(arms)
    out = set()
    for exts, body, fn in arms:
        if kind == "tag":
            # Comment lines are stripped before the match. The tag literal is
            # evidence that this arm EMITS the category, and a mention in a
            # comment ("# TODO: also emit "unclosed-handle" here") is not that —
            # it would prove coverage the arm does not have, silencing the very
            # MISMATCH this assertion exists to raise. Cheap to exclude, and the
            # failure it prevents is silent.
            if '"%s"' % key in strip_comments(body):
                out |= exts
        elif kind == "fn":
            if fn == key[runtime]:
                out |= exts
    return out

# --- the normative table -----------------------------------------------------
# Parsed out of loc_engine.py's EXT_LANG literal rather than imported: this gate
# must not execute scanner code, and the literal is a flat str->str dict by the
# column-zero rule that validate-shared-scanner-sync.sh already enforces.
NORMATIVE_SRC = os.path.join(SKILLS, "check-decomposition", "loc_engine.py")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def parse_ext_lang(src):
    m = re.search(r"^EXT_LANG\s*=\s*\{(.*?)^\}", src, re.M | re.S)
    if not m:
        return {}
    return dict(re.findall(r'"([A-Za-z0-9]+)"\s*:\s*"([A-Za-z0-9]+)"', m.group(1)))


def parse_comment_re(src):
    """lang -> comment-marker regex, from a COMMENT_RE dict literal.

    Same shape and same reason as parse_ext_lang: a flat `"key": re.compile(r"…")`
    literal closed by a column-zero `}`. The value captured is the raw pattern
    text, which is what the subset assertion compares.
    """
    m = re.search(r"^COMMENT_RE\s*=\s*\{(.*?)^\}", src, re.M | re.S)
    if not m:
        return {}
    return dict(
        re.findall(
            r'"([A-Za-z0-9]+)"\s*:\s*re\.compile\(\s*r"([^"]*)"', m.group(1)
        )
    )


normative = {}
normative_comments = {}
if os.path.exists(NORMATIVE_SRC):
    normative = parse_ext_lang(read(NORMATIVE_SRC))
    normative_comments = parse_comment_re(read(NORMATIVE_SRC))
print("NORMATIVE %d" % len(normative))
print("NORMATIVE_COMMENTS %d" % len(normative_comments))

# --- what each scanner dispatches on ----------------------------------------
# Python side: `ext == "x"` and `ext in ("x", "y")`. Bash side: `*.[Xx][Yy])`
# case arms, bracket classes collapsed. Both yield a set of lowercase extensions
# per file.
BRACKET = re.compile(r"\[([A-Za-z])[A-Za-z]\]")
ARM = re.compile(r"^\s*(\*\.[A-Za-z0-9\[\]]+(?:\s*\|\s*\*\.[A-Za-z0-9\[\]]+)*)\)", re.M)


def _pats_to_exts(patterns):
    """`*.[Jj][Ss] | *.[Tt][Ss]` -> {'js', 'ts'}. Bracket classes collapsed."""
    out = set()
    for pat in patterns.split("|"):
        pat = pat.strip()
        if not pat.startswith("*."):
            continue
        out.add(BRACKET.sub(lambda m: m.group(1).lower(), pat[2:]).lower())
    return out


# --- arm-level extraction (#847) --------------------------------------------
# Both runtimes are walked as a LIST OF ARMS rather than as one flat set of
# extensions, because a matrix column names one detector family and a scanner
# holds several. Each arm carries the extensions it dispatches on, the source
# text of its body, and the function enclosing it — the three things the binding
# map below can key on. The whole-file union is still available as the union of
# every arm, which is what the `file` binding kind uses.


def py_arms(src):
    """[(exts, body, enclosing_fn)] for each `if/elif ext ==/in (...)` arm.

    Python arms are indentation-delimited: the body runs until the first
    non-blank line indented no further than the `if` itself.
    """
    lines = src.splitlines()
    out = []
    fn = ""
    for i, line in enumerate(lines):
        named = re.match(r"^def\s+(\w+)", line)
        if named:
            fn = named.group(1)
        m = re.match(r"^(\s*)(?:el)?if\s+ext\s*==\s*\"([a-z0-9]+)\"\s*:", line)
        if m:
            indent, exts = len(m.group(1)), {m.group(2)}
        else:
            m = re.match(r"^(\s*)(?:el)?if\s+ext\s+in\s*\(([^)]*)\)\s*:", line)
            if not m:
                continue
            indent = len(m.group(1))
            exts = set(re.findall(r'"([a-z0-9]+)"', m.group(2)))
        body = []
        for nxt in lines[i + 1 :]:
            if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
                break
            body.append(nxt)
        out.append((exts, "\n".join(body), fn))
    return out


def sh_arms(src):
    """[(exts, body, enclosing_fn)] for each `*.[Xx][Yy])` case arm.

    The body runs to `;;`. CRITICAL: `;;` may sit on the PATTERN LINE ITSELF
    (`*.md | *.json) continue ;;` in check-lifecycle/patterns.sh). Scanning
    forward unconditionally would run past such an arm and absorb the arms after
    it — the probe for #847 saw exactly that, and it reported md/json/yaml/toml
    as phantom coverage of every lifecycle category. Same shape as an end-marker
    that silently over-grows its region: the START matched, so nothing errors;
    the region just quietly grows. Hence the same-line check FIRST.
    """
    lines = src.splitlines()
    out = []
    fn = ""
    for i, line in enumerate(lines):
        named = re.match(r"^(\w+)\s*\(\)\s*\{", line)
        if named:
            fn = named.group(1)
        # A `}` in COLUMN ZERO closes the function. Tracking only the opener
        # leaves every later top-level arm attributed to the last function seen —
        # check-code-health's empty-handler `case` is top-level and sits after
        # scan_debugger_statements(), so without this reset its `go` arm is read
        # as debugger coverage and the correct `—` cell is reported as a defect.
        elif re.match(r"^\}", line):
            fn = ""
        m = ARM.match(line)
        if not m:
            continue
        exts = _pats_to_exts(m.group(1))
        rest = line[m.end() :]
        if ";;" in rest:
            out.append((exts, rest.split(";;")[0], fn))
            continue
        body = [rest]
        for nxt in lines[i + 1 :]:
            if ";;" in nxt:
                body.append(nxt.split(";;")[0])
                break
            body.append(nxt)
        out.append((exts, "\n".join(body), fn))
    return out


def arm_exts(arms):
    """Whole-file union — every extension dispatched anywhere."""
    out = set()
    for exts, _body, _fn in arms:
        out |= exts
    return out


# A bash `lang="x"` assignment names the language for an arm; when present it is
# a direct claim about the mapping and is checked against the normative table.
def sh_lang_pairs(src):
    pairs = []
    for arm, lang in re.findall(
        r"^\s*(\*\.[A-Za-z0-9\[\]|\s*.]+?)\)\s*lang=\"([a-z0-9]+)\"", src, re.M
    ):
        for pat in arm.split("|"):
            pat = pat.strip()
            if not pat.startswith("*."):
                continue
            ext = BRACKET.sub(lambda m: m.group(1).lower(), pat[2:]).lower()
            pairs.append((ext, lang))
    return pairs


# --- assertion 3: no contradiction ------------------------------------------
# Walk EVERY dispatch site under plugins/, not just the four governed scanners:
# the unpinned check-decomposition <-> sizing.sh bash tables are covered here.
for dirpath, _dirs, files in os.walk(PLUGINS):
    for name in sorted(files):
        if not name.endswith(".sh"):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, ROOT)
        for ext, lang in sh_lang_pairs(read(path)):
            want = normative.get(ext)
            if want is not None and want != lang:
                print(
                    "CONTRADICTION %s: .%s -> %r, normative says %r"
                    % (rel, ext, lang, want)
                )

# --- assertion 3b: no COMMENT-MARKER contradiction (#838) --------------------
# ADR 0002 § 2 governs two lexical facts, not one: "an extension it dispatches on
# must map to the same language key, AND a comment marker it uses for a language
# must match the normative one". Assertion 3 above covered only the first half —
# this gate's own header claimed both from Phase 0, but nothing checked markers
# because no scanner carried a comment-model subset until #622 Phase 1 shipped
# the lexical gating. Now that one exists, the claim is enforced rather than
# asserted.
#
# Same subset polarity as everywhere else here: a scanner may model FEWER
# languages than the normative table, but a language it DOES model must carry the
# normative marker verbatim. A silently divergent marker is the exact bug the
# gating was built to remove — it would make a detector read one language's
# source under another's comment rules.
for dirpath, _dirs, files in os.walk(PLUGINS):
    for name in sorted(files):
        if name != "patterns.py":
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, ROOT)
        if os.path.samefile(path, NORMATIVE_SRC) if os.path.exists(path) else False:
            continue
        for lang, pattern in parse_comment_re(read(path)).items():
            want = normative_comments.get(lang)
            if want is not None and want != pattern:
                print(
                    "COMMENT_CONTRADICTION %s: %r -> %r, normative says %r"
                    % (rel, lang, pattern, want)
                )

# --- the contract matrices ---------------------------------------------------
# A row is `| Name | ext, ext | cell | cell |`. The language is column 2 (the
# extension list); a row whose cell set contains an `M` is modeled, a row whose
# cells are all `—` is unsupported. The catch-all row ("every other extension")
# names no extension and is skipped.
CELL_M = "M"
CELL_NONE = "—"  # em dash


def split_row(row):
    """Split a markdown table row on UNESCAPED pipes.

    An ODD number of preceding backslashes escapes the pipe; an EVEN number is
    literal backslashes followed by a real separator. A one-character lookbehind
    (`(?<!\\\\)`) gets `...\\\\|` wrong in exactly the way a bare `.split("|")`
    gets `\\|` wrong — columns shift left and a prose fragment is read as the
    cell state. Written as a scan rather than a regex because Python's `re` has
    no `\\K`, and the lookbehind alternative is unreadable.

    No contract row exercises `\\\\|` today; spelled correctly because the
    failure mode is silent misalignment, not an error.
    """
    out, buf, i = [], [], 0
    while i < len(row):
        ch = row[i]
        if ch == "\\" and i + 1 < len(row):
            buf.append(row[i : i + 2])  # keep the escape pair intact
            i += 2
            continue
        if ch == "|":
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    out.append("".join(buf))
    return out


def parse_matrix(md, skill):
    """Return {(ext, column): 'M'|'-'} for one scanner's Language Support matrix.

    PER CELL, not per row (#847). The previous version OR-ed a row's columns into
    one state, so a wrong cell in one column passed whenever any OTHER column had
    an arm for that extension — which is the whole defect, and it is invisible
    precisely where the matrices are ragged on purpose (check-code-health's
    empty-handler covers .js/.jsx/.ts/.tsx while both debug families also cover
    .mjs/.cjs).

    Returns (headers, cells) so a caller can report the column by name.
    """
    start = md.find("<!-- contract: %s-language-support -->" % skill)
    if start < 0:
        return None
    end = md.find("<!-- contract: end-%s-language-support -->" % skill, start)
    if end < 0:
        return None
    out = {}
    headers = []
    for line in md[start:end].splitlines():
        line = line.strip()
        if not line.startswith("|") or line.startswith("| ---"):
            continue
        # Split on UNESCAPED pipes only. A markdown cell may contain `\|` — and
        # one does: check-docs-missing-api's "public-symbol form" column spells
        # an alternation as `export function\|class\|const\|…`. Splitting on a
        # bare "|" shatters that row into extra columns and shifts every later
        # cell left, so the parser reads a prose fragment where the M/— state
        # should be. The row-level check never saw this because it OR-ed the
        # whole row; per-cell alignment makes it load-bearing.
        cols = [c.strip().replace("\\|", "|") for c in split_row(line.strip().strip("|"))]
        if len(cols) < 3:
            continue
        if cols[0] == "Language":
            headers = cols[2:]
            continue
        if not headers:
            continue
        exts = [e.strip() for e in cols[1].split(",") if e.strip()]
        if not exts:
            continue  # the catch-all row
        for col_idx, cell in enumerate(cols[2:]):
            if col_idx >= len(headers):
                break
            state = CELL_M if CELL_M in cell else "-"
            # A cell may carry a parenthetical narrowing — "M (js/jsx only)".
            # Under the old ROW-level check that was necessarily prose: there was
            # no per-cell state for it to qualify. Per-cell it becomes machine
            # -readable and is ENFORCED, which is the point of #847 — that cell
            # is precisely check-code-health's documented raggedness (empty-
            # handler covers .js/.jsx/.ts/.tsx but not .mjs/.cjs). Read as `M`
            # for the extensions it names and `-` for the rest of the row, so the
            # gate demands arms exactly where the contract promises them.
            narrowed = None
            paren = re.search(r"\(([^)]*)\bonly\)", cell)
            if state == CELL_M and paren:
                narrowed = {
                    t for t in re.findall(r"[a-z0-9]+", paren.group(1)) if t != "only"
                }
            for e in exts:
                if not re.fullmatch(r"[a-z0-9]+", e):
                    continue
                cell_state = state
                if narrowed is not None:
                    cell_state = CELL_M if e in narrowed else "-"
                out[(e, headers[col_idx])] = cell_state
    return headers, out


# --- assertions 2 + 4 --------------------------------------------------------
for skill in GOVERNED:
    contract = os.path.join(SKILLS, skill, "contract.md")
    py = os.path.join(SKILLS, skill, "patterns.py")
    sh = os.path.join(SKILLS, skill, "patterns.sh")
    if not any(os.path.exists(p) for p in (contract, py, sh)):
        # The scanner is absent entirely. In the real tree that cannot happen;
        # in a negative fixture it is how a tree arms ONE assertion without
        # tripping its siblings as collateral. A PARTIALLY present scanner is
        # still a defect and falls through to the check below.
        continue
    if not (os.path.exists(contract) and os.path.exists(py) and os.path.exists(sh)):
        print("MISMATCH %s: missing contract.md/patterns.py/patterns.sh" % skill)
        continue

    parsed = parse_matrix(read(contract), skill)
    if parsed is None:
        print("NOMATRIX %s" % skill)
        continue
    headers, matrix = parsed
    print("MATRIX %s %d" % (skill, len(matrix)))

    arms_py = py_arms(read(py))
    arms_sh = sh_arms(read(sh))
    bindings = BINDINGS.get(skill, {})

    # Resolve each bound column's region ONCE per runtime, and fail loud on a
    # binding that resolves to nothing. Without this the narrowing rots
    # silently: rename `_scan_debugger`, or change an emitted tag, and the
    # region simply stops matching — every cell in that column would then be
    # compared against an EMPTY set, so `—` cells pass trivially and only `M`
    # cells fail, in a way that reads as a scanner bug rather than a stale
    # binding. Measured absence of a region is a defect in THIS gate.
    resolved = {}
    for column in sorted(bindings):
        # Only columns THIS matrix actually declares. The map is written against
        # the real tree, and a fixture carries a deliberate subset of columns for
        # the same reason it carries a subset of scanners — so an unused binding
        # is not a defect, it is a column this matrix does not have. Checking it
        # anyway makes every fixture trip assertion 5 as collateral, which is
        # precisely the "fixture arms exactly one assertion" property the
        # fixtures README states.
        if column not in headers:
            continue
        kind, key = bindings[column]
        got_py = bound_exts(kind, key, arms_py, 0)
        got_sh = bound_exts(kind, key, arms_sh, 1)
        resolved[column] = (got_py, got_sh)
        if not got_py:
            print("VACUOUS %s: binding for column %r matches no patterns.py arm"
                  % (skill, column))
        if not got_sh:
            print("VACUOUS %s: binding for column %r matches no patterns.sh arm"
                  % (skill, column))

    for (ext, column), state in sorted(matrix.items()):
        if column not in resolved:
            # An `M` cell in a column nothing binds is unenforceable — report it
            # rather than pass over it, so adding a modeled column without a
            # binding fails loudly instead of quietly going unchecked. `L` and
            # `—` cells in an unbound column are the documented Phase 1 gap.
            if state == CELL_M:
                print("UNBOUND %s: .%s marked M in column %r, which has no binding"
                      % (skill, ext, column))
            continue
        got_py, got_sh = resolved[column]
        in_py, in_sh = ext in got_py, ext in got_sh
        if state == CELL_M:
            if not in_py:
                print("MISMATCH %s: .%s marked M in column %r, no patterns.py arm"
                      % (skill, ext, column))
            if not in_sh:
                print("MISMATCH %s: .%s marked M in column %r, no patterns.sh arm"
                      % (skill, ext, column))
        else:
            if in_py:
                print("MISMATCH %s: .%s marked unsupported in column %r, "
                      "patterns.py has an arm" % (skill, ext, column))
            if in_sh:
                print("MISMATCH %s: .%s marked unsupported in column %r, "
                      "patterns.sh has an arm" % (skill, ext, column))

    # A language the matrix does not mention at all, but both runtimes dispatch
    # on, is an UNDECLARED arm — the drift the matrix exists to prevent. Stays
    # whole-file: it asks whether the matrix names the LANGUAGE, which is a
    # row-level question and independent of any column.
    declared = {e for e, _c in matrix}
    for ext in sorted(arm_exts(arms_py) & arm_exts(arms_sh)):
        if ext not in declared and ext in normative:
            print("MISMATCH %s: .%s dispatched in both runtimes, not in matrix" % (skill, ext))
PY
)"

# report_lines TAG — echo the report rows carrying TAG, or nothing.
report_lines() {
    command printf '%s\n' "$LANG_REPORT" | command grep -E "^$1 " || true
}

# --- Assertion 1: anti-vacuity, the normative table ------------------------
test_normative_table_populated() {
    local count
    count="$(report_lines NORMATIVE | command sed -n 's/^NORMATIVE //p')"
    # No assert_true anywhere in this gate: it evals its command string, and
    # every value here is analyzer-derived. Compare in bash, report via a
    # parameter-taking assertion. See the NOTE above test_no_contradiction.
    # `case` on a quoted value, then assert_equals on the VERDICT — neither evals.
    # A non-digit or absent count is as much a failure as a zero one: it means the
    # analyzer did not report, which is precisely the vacuity this guards.
    local verdict="populated"
    case "$count" in
        '' | *[!0-9]*) verdict="unparseable (got: '${count:-<none>}')" ;;
        0) verdict="parsed but EMPTY" ;;
    esac
    assert_equals "populated" "$verdict" "normative EXT_LANG parsed and non-empty"
}

# --- Assertion 2: anti-vacuity, the matrices --------------------------------
# TWO halves, and both are needed.
#
# (a) A scanner that EXISTS but resolves no matrix is a defect — reported as
#     NOMATRIX by the analyzer. This is the half a negative fixture arms.
# (b) In the REAL tree, all four must be present. Guarded by NAME SET rather
#     than by count: a gate asserting "4 matrices" still passes when one skill's
#     matrix is silently swapped for a duplicate of another's (#596). Skipped
#     under a fixture root, where a tree deliberately carries a subset.
test_no_unmatched_scanner() {
    local bad
    bad="$(report_lines NOMATRIX)"
    assert_output_empty "$bad" \
        "every present scanner resolves a Language Support matrix"
}

# LANG_TABLE_EXPECT_ROSTER — force the four-scanner roster check ON under a
# fixture root. Without it the check skips there, since a fixture tree carries a
# deliberate subset. But "skips under every fixture" means its FAILING branch is
# never executed by anything, which is the self-skipping-hides-the-risky-branch
# shape (#543): the arm that matters is the one no test reaches. The
# missing-roster fixture sets this so the branch is genuinely exercised.
LANG_TABLE_EXPECT_ROSTER="${LANG_TABLE_EXPECT_ROSTER:-}"

test_matrices_present() {
    local found skill declared
    if [ "$LANG_TABLE_ROOT" != "$REPO_ROOT" ] && [ -z "$LANG_TABLE_EXPECT_ROSTER" ]; then
        skip_test "fixture root — the four-scanner roster applies to the real tree"
        return 0
    fi
    found="$(report_lines MATRIX | command awk '{print $2}' | command sort)"
    for skill in check-security check-code-health check-lifecycle check-docs-missing-api; do
        if command printf '%s\n' "$found" | command grep -qx "$skill"; then
            declared="yes"
        else
            declared="no"
        fi
        assert_equals "yes" "$declared" "$skill declares a Language Support matrix"
    done
}

test_matrices_non_empty() {
    local line skill count nonempty
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        skill="$(command printf '%s' "$line" | command awk '{print $2}')"
        count="$(command printf '%s' "$line" | command awk '{print $3}')"
        if [ "$count" -gt 0 ] 2>/dev/null; then
            nonempty="yes"
        else
            nonempty="no"
        fi
        assert_equals "yes" "$nonempty" \
            "$skill's matrix names at least one cell (got $count)"
    done <<EOF
$(report_lines MATRIX)
EOF
}

# --- Assertion 3: no contradiction with the normative table ------------------
# NOTE — these use assert_output_empty, NOT assert_true, and that is a security
# property rather than a style choice. assert_true EVALs its command string
# (tests/lib/harness.sh: `eval "$cmd"`), and a CONTRADICTION row embeds `rel`,
# the on-disk relative path of any *.sh the walk finds under plugins/. That path
# is attacker-controlled in the only sense that matters here: a PR can add a file
# whose NAME contains `$(...)` or backticks without touching this gate at all,
# and the substitution would then execute when CI or pre-push runs it. The
# extension/language tokens are `[a-z0-9]+`-constrained; the path is not.
# assert_output_empty takes the value as a PARAMETER and never evals it.
test_no_contradiction() {
    local bad
    bad="$(report_lines CONTRADICTION)"
    assert_output_empty "$bad" \
        "no dispatch site contradicts the normative EXT_LANG"
}

# --- Assertion 3b: no comment-marker contradiction (#838) --------------------
# The second half of ADR 0002 § 2, unenforced until Phase 1 gave it something to
# check. Same assert_output_empty reasoning as above — a COMMENT_CONTRADICTION
# row embeds a path.
test_no_comment_contradiction() {
    local bad
    bad="$(report_lines COMMENT_CONTRADICTION)"
    assert_output_empty "$bad" \
        "no scanner's comment model contradicts the normative COMMENT_RE"
}

# Anti-vacuity for 3b: the normative COMMENT_RE must actually have parsed, or the
# assertion above compares every subset entry against None and passes for free.
# Mirrors test_normative_table_populated, and for the same reason.
#
# Scoped to the REAL repo root, like the roster check at test_governed_roster:
# the self-test fixture trees carry a minimal loc_engine.py with an EXT_LANG and
# no COMMENT_RE (they were built before this assertion existed and exercise the
# EXT_LANG half), so under a fixture root a zero count is expected rather than a
# defect. The floor still binds where it matters — nothing may quietly drop the
# normative comment models out of the real tree.
test_normative_comments_populated() {
    if [ "$LANG_TABLE_ROOT" != "$REPO_ROOT" ]; then
        skip_test "not the real repo root — fixture loc_engine.py carries no COMMENT_RE"
        return
    fi
    local count
    count="$(report_lines NORMATIVE_COMMENTS | command sed -n 's/^NORMATIVE_COMMENTS //p')"
    local verdict="populated"
    case "$count" in
        '' | *[!0-9]*) verdict="unparseable (got: '${count:-<none>}')" ;;
        0 | 1 | 2 | 3 | 4) verdict="parsed only $count entries (expected >= 5)" ;;
    esac
    assert_equals "populated" "$verdict" "normative COMMENT_RE parsed and non-empty"
}

# --- Assertion 4: the matrix matches both runtimes, PER CELL -----------------
test_matrix_matches_source() {
    local bad
    bad="$(report_lines MISMATCH)"
    assert_output_empty "$bad" \
        "every matrix cell matches both runtimes"
}

# --- Assertion 5: anti-vacuity, the column bindings themselves (#847) --------
# The per-cell narrowing is only as good as the binding map that backs it, and a
# stale binding degrades QUIETLY — see the comment on `resolved` in the analyzer.
# So a binding matching no arm in either runtime is its own failure, separate
# from the cell comparisons it feeds. Same anti-vacuity discipline the normative
# table and the matrices already get.
test_bindings_resolve() {
    local bad
    bad="$(report_lines VACUOUS)"
    assert_output_empty "$bad" \
        "every column binding resolves to at least one arm in both runtimes"
}

# --- Assertion 6: no modeled column escapes the binding map (#847) -----------
# An `M` cell in an unbound column would be unenforceable. Reporting it keeps the
# map honest as columns are added — the alternative is a new modeled column that
# silently goes unchecked, which is the same shape as the defect #847 fixes.
test_modeled_columns_bound() {
    local bad
    bad="$(report_lines UNBOUND)"
    assert_output_empty "$bad" \
        "every column with an M cell has a source-region binding"
}

run_test test_normative_table_populated "normative EXT_LANG is populated (anti-vacuity)"
run_test test_no_unmatched_scanner "a present scanner resolves its matrix (anti-vacuity)"
run_test test_matrices_present "all four governed scanners declare a matrix (anti-vacuity)"
run_test test_matrices_non_empty "each matrix names at least one cell"
run_test test_no_contradiction "no dispatch site contradicts the normative table"
run_test test_normative_comments_populated "normative COMMENT_RE is populated (anti-vacuity)"
run_test test_no_comment_contradiction "no scanner comment model contradicts the normative table"
run_test test_matrix_matches_source "matrix M/unsupported cells match both runtimes"
run_test test_bindings_resolve "every column binding resolves in both runtimes (anti-vacuity)"
run_test test_modeled_columns_bound "every modeled column has a binding"

# --- Self-tests: each assertion actually fires -------------------------------
#
# The five checks above are green on this tree, which is necessary and proves
# nothing on its own — a detector that never fires is green too, and that is this
# repo's most-recorded failure mode (#596, #599, #600). So each assertion is
# re-run against a committed negative fixture that arms IT and only it.
#
# Committed trees under tests/fixtures/language-table/, not transient mutations,
# for the reason tests/fixtures/category-parity/ is committed: the proof has to
# re-run on every future invocation, not only on the day it was written.
#
# Fixtures are only run when the gate is pointed at the real tree — a nested
# self-test under a fixture root would recurse.
FIXROOT="$SCRIPT_DIR/fixtures/language-table"

# selftest_report FIXTURE — the analyzer's findings for one fixture tree, via a
# recursive call to this script with LANG_TABLE_ROOT redirected. Prints the
# harness output; callers grep it for the specific failing assertion.
# selftest_report FIXTURE [ROSTER] — pass a non-empty second arg to also set
# LANG_TABLE_EXPECT_ROSTER, which arms the roster check that otherwise skips
# under a fixture root.
selftest_report() {
    LANG_TABLE_ROOT="$FIXROOT/$1" LANG_TABLE_EXPECT_ROSTER="${2:-}" \
        command bash "$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")" 2>&1 || true
}

test_selftest_fixtures() {
    if [ "$LANG_TABLE_ROOT" != "$REPO_ROOT" ]; then
        skip_test "already under a fixture root — self-tests do not recurse"
        return 0
    fi

    local out

    out="$(selftest_report empty-normative)"
    assert_contains "$out" "normative EXT_LANG is populated (anti-vacuity) ... FAIL" \
        "empty-normative fixture must fail the normative-table assertion"

    out="$(selftest_report no-marker)"
    assert_contains "$out" "a present scanner resolves its matrix (anti-vacuity) ... FAIL" \
        "no-marker fixture must fail the matrix-resolution assertion"

    out="$(selftest_report contradiction)"
    assert_contains "$out" "no dispatch site contradicts the normative table ... FAIL" \
        "contradiction fixture must fail the no-contradiction assertion"

    out="$(selftest_report one-runtime)"
    assert_contains "$out" "matrix M/unsupported cells match both runtimes ... FAIL" \
        "one-runtime fixture must fail the matrix<->source assertion"
    assert_contains "$out" "no patterns.sh arm" \
        "one-runtime fixture must name the missing bash arm specifically"

    # The per-CATEGORY fixture (#847). The one fixture with a MULTI-column
    # matrix — every other tree here uses a single synthetic column and so
    # cannot express this defect at all, which is why the gap survived Phase 0.
    #
    # It is a genuine regression test, not a restatement of one-runtime:
    # verified to PASS against the pre-#847 gate (the row-collapsing version)
    # and FAIL against this one. `.rs` IS dispatched in both runtimes, so the
    # whole-file union satisfies the old check; only the per-category narrowing
    # sees that the `unclosed-handle` region lacks the arm.
    out="$(selftest_report per-category)"
    assert_contains "$out" "matrix M/unsupported cells match both runtimes ... FAIL" \
        "per-category fixture must fail the matrix<->source assertion"
    assert_contains "$out" "column 'unclosed-handle'" \
        "per-category fixture must name the offending COLUMN, not just the language"
    # Narrowness: the sibling column is correct and must NOT be reported. Without
    # this the assertion above passes just as well on a gate that flags every
    # column of the row — which is the row-collapsing behavior #847 removes.
    assert_not_contains "$out" "column 'unreaped-subprocess'" \
        "per-category fixture must not flag the column that IS correct"

    # The arm-delimiting fixture (#847). The ONLY POSITIVE fixture here — it must
    # PASS, where every other one arms a failure. That inversion is the point:
    # the property is that a bash arm whose `;;` sits on the pattern line does
    # NOT leak its successor's coverage, and a leak shows up as a spurious
    # finding against a correct tree. So the failure mode is a false POSITIVE,
    # and only a clean run can pin it.
    #
    # Kept because a mutation round found the same-line branch untested, not
    # unreachable: neutering it silently added md/json/yaml coverage to every
    # real check-lifecycle category, and nothing failed — those extensions are
    # absent from both the matrix and EXT_LANG, so every comparison stayed
    # silent. This fixture puts the phantom extension somewhere observable.
    out="$(selftest_report sameline-arm)"
    assert_not_contains "$out" "FAIL" \
        "sameline-arm fixture must pass — a same-line ';;' arm must not leak coverage"
    assert_contains "$out" "matrix M/unsupported cells match both runtimes ... PASS" \
        "sameline-arm fixture must actually REACH the per-cell assertion"

    # Assertions 5 and 6 get the same treatment as 1-4. Without these two
    # fixtures both were trivially green on every tree this repo will ever run —
    # BINDINGS is hand-curated to match the live matrices, so neither FAIL branch
    # was reachable, and deleting the detection outright kept the suite green
    # (verified). That is the self-skipping-hides-the-risky-branch shape (#543)
    # this file already fixes for the roster check, applied to the assertions
    # added alongside it.
    # TWO fixtures, one per runtime, each vacuous in ONE half only. A tree
    # vacuous in BOTH cannot separate the detection branches: `if not got_py` and
    # `if not got_sh` each report it alone, so deleting either survives —
    # measured, both single-branch mutations survived a symmetric fixture. The
    # asymmetric pair is what pins each branch. Assert the RUNTIME NAME, not just
    # the column, or the pair collapses back into one test.
    out="$(selftest_report vacuous-binding)"
    assert_contains "$out" "every column binding resolves in both runtimes (anti-vacuity) ... FAIL" \
        "vacuous-binding fixture must fail the binding anti-vacuity assertion"
    assert_contains "$out" "column 'unclosed-handle' matches no patterns.py arm" \
        "vacuous-binding fixture must name the empty PYTHON binding specifically"
    assert_not_contains "$out" "matches no patterns.sh arm" \
        "vacuous-binding fixture must leave the bash half non-vacuous (pins the py branch)"

    out="$(selftest_report vacuous-binding-sh)"
    assert_contains "$out" "every column binding resolves in both runtimes (anti-vacuity) ... FAIL" \
        "vacuous-binding-sh fixture must fail the binding anti-vacuity assertion"
    assert_contains "$out" "column 'unclosed-handle' matches no patterns.sh arm" \
        "vacuous-binding-sh fixture must name the empty BASH binding specifically"
    assert_not_contains "$out" "matches no patterns.py arm" \
        "vacuous-binding-sh fixture must leave the python half non-vacuous (pins the sh branch)"

    out="$(selftest_report unbound-column)"
    assert_contains "$out" "every modeled column has a binding ... FAIL" \
        "unbound-column fixture must fail the modeled-column-bound assertion"
    assert_contains "$out" "column 'future-detector'" \
        "unbound-column fixture must name the unbound column"
    assert_contains "$out" "every column binding resolves in both runtimes (anti-vacuity) ... PASS" \
        "unbound-column fixture must arm ONLY assertion 6, not the vacuity check"

    # The `fn` and `file` binding kinds, plus the two parse behaviors that ride
    # on the same tree. POSITIVE (must pass) for the reason sameline-arm is: a
    # regression here shows up as a spurious finding against a correct tree.
    # Mutation-verified — collapsing fn tracking, reverting the escaped-pipe
    # splitter, and dropping the narrowing parenthetical are each caught.
    out="$(selftest_report fn-file-kinds)"
    assert_not_contains "$out" "FAIL" \
        "fn-file-kinds fixture must pass — fn/file bindings and cell parsing are correct"
    assert_contains "$out" "matrix M/unsupported cells match both runtimes ... PASS" \
        "fn-file-kinds fixture must actually REACH the per-cell assertion"

    # A tag MENTIONED in a comment is not an emission. Positive fixture, same
    # shape as the two above: the failure it guards against is a false claim of
    # coverage, which shows up as a spurious MISMATCH against a truthful matrix.
    out="$(selftest_report tag-in-comment)"
    assert_not_contains "$out" "FAIL" \
        "tag-in-comment fixture must pass — a tag in a comment is not coverage"
    assert_contains "$out" "matrix M/unsupported cells match both runtimes ... PASS" \
        "tag-in-comment fixture must actually REACH the per-cell assertion"

    # The roster check skips under every OTHER fixture root, so without this its
    # failing branch is executed by nothing — the self-skipping-hides-the-risky-
    # branch shape (#543). Armed explicitly here.
    out="$(selftest_report missing-roster 1)"
    assert_contains "$out" "all four governed scanners declare a matrix (anti-vacuity) ... FAIL" \
        "missing-roster fixture must fail the four-scanner roster assertion"
    assert_contains "$out" "check-security declares a Language Support matrix" \
        "missing-roster fixture must name the undeclared scanner"
}

run_test test_selftest_fixtures "self-test: each assertion fires on its fixture"

generate_report
