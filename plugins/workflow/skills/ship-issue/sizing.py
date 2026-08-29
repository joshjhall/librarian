#!/usr/bin/env python3
"""ship-issue — review-lens sizing pre-scan (Python primary implementation).

The adversarial pre-PR review had no size lens — a PR could add 900 lines to an
already-oversized file and pass a clean review (issue #695). This scanner
supplies the candidates the new `decomposition` dimension judges.

WHY THIS IS NOT check-decomposition. The audit-lens scanner
(review-audit/skills/check-decomposition) answers "is this file too long?" over a
whole repo. A per-PR gate must answer a DIFFERENT question — "did THIS diff make
it worse?" — because a one-line touch to a pre-existing 1,200-line file is not
the author's debt to pay, and a reviewer that says otherwise gets turned off
within a week. So this scanner is GROWTH-AWARE: it reads a numstat sidecar and
dispositions each file by what the diff actually did to it.

The LOC-counting rules themselves are NOT re-derived. They are physically shared
with check-decomposition through `# >>> shared:loc-*` sentinel regions pinned
byte-for-byte by tests/validate-shared-scanner-sync.sh — the plugins install
independently (workflow without review-audit), so a sourced library is
impossible and a third drifting copy of the LOC rules is exactly what #663 was
filed to kill. Both the Python primaries (`shared:loc-*-py`) and the awk
fallbacks (`shared:loc-*-awk`) are pinned; before #730 only the awk half was,
so the two Python halves — the ones that actually run whenever a python3>=3.11
is present — could drift freely while every gate stayed green.

PROSE FILE-TYPE CLASSIFICATION is shared the same way (`shared:bloat-spec-py`,
#724). Before it, this lens sized every .md by the generic 700/1000 md pair, so
an `agents/*.md` well over its own 250/400 budget — flagged HIGH by the audit
lens — passed a per-PR review in silence. Strictness is a policy dial each lens
owns; what a file IS is a fact about its path and must not fork. The DISPOSITION
below stays this lens's own: classified prose is still growth-graded, so a
one-line touch to a pre-existing over-budget file is LOW, never blocking.

Python 3.11+ primary behind the language-agnostic TSV contract; the sibling
sizing.sh is the portable bash fallback (it exec's this file when a python3>=3.11
is present). Both emit byte-identical findings — parity pinned by
tests/validate-python-ports.sh, behavior by tests/validate-sizing-scanner.sh.
See CLAUDE.md § Key conventions (runtime policy).

Input:  argv[1] = file containing paths to scan (one per line)
                  (or `--measure` followed by that file — see measure_record())
        argv[2] = OPTIONAL numstat sidecar: `added<TAB>deleted<TAB>path` rows
                  (`git diff --numstat`). ABSENT => no growth signal, so every
                  over-threshold file is reported at LOW/informational only.
Output: TSV to stdout: file<TAB>line<TAB>category<TAB>evidence<TAB>certainty

The 5-column contract is NOT widened — it is the language boundary every
check-* skill and all three parity gates depend on.

Exit codes:
  0 = success (zero or more findings)
  1 = usage error (missing argument) or file list not found
"""

from __future__ import annotations

import os
import re
import sys

# The LOC engine and prose spec live in sibling modules (#772). Both entry
# scanners were over the 800 production-LOC py budget and could not be split
# until tests/validate-shared-scanner-sync.sh learned pair members that span
# several files.
#
# sys.path seeding rather than a package: this file is executed directly
# (`python3 sizing.py`, which is how the sibling sizing.sh shim exec's it), so there
# is no package context and a relative import would fail. The same idiom as
# ship-issue/split-verify.py.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from loc_engine import (  # noqa: E402
    Unit,
    _int_env,
    emit,
    find_units,
    is_decl_file,
    is_test_file,
    lang_of,
    measure,
    split_shape,
)
from prose_spec import (  # noqa: E402
    _bundle_root,
    bloat_spec,
    bundle_kind,
    bundle_seam_rows,
)

# `_bundle_root` is imported but NOT called here — it is RE-EXPORTED for
# split-verify.py, which does `from sizing import _bundle_root` (#772). Before
# the split it was defined in this file; keeping the name importable from here
# is what makes the split invisible to that consumer, which lives in this same
# directory and correctly prefers an import over duplication.
__all__ = [
    "Unit",
    "_bundle_root",
    "_int_env",
    "bundle_kind",
    "emit",
    "find_units",
    "lang_of",
    "measure",
]


# Non-source files skipped wholesale. Mirrors check-decomposition's SKIP_GLOBS.
# Markdown is deliberately ABSENT: prose is the surface this repo feels most
# (#589), and the markdown arm carries its own progressive-disclosure guidance.
SKIP_EXTS = (
    ".lock",
    ".txt",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".ini",
    ".cfg",
    ".conf",
)

GENERATED_RE = re.compile(
    r"@generated|Code generated by|DO NOT EDIT|autogenerated|auto-generated",
    re.IGNORECASE,
)


# Per-language review-lens thresholds, overriding the default pair. A 500-line
# Rust file and a 500-line shell script are not the same claim. Languages absent
# here fall through to REVIEW_LOC_WARN/HIGH — adding one is a one-line edit, and
# an unlisted language is sized rather than silently skipped.
#
# Mirrors the per_language block of check-decomposition/thresholds.yml.
PER_LANG_THRESHOLDS = {
    "sh": ("REVIEW_LOC_WARN_SH", "REVIEW_LOC_HIGH_SH", 700, 1000),
    "md": ("REVIEW_LOC_WARN_MD", "REVIEW_LOC_HIGH_MD", 700, 1000),
    "rs": ("REVIEW_LOC_WARN_RS", "REVIEW_LOC_HIGH_RS", 400, 700),
    "go": ("REVIEW_LOC_WARN_GO", "REVIEW_LOC_HIGH_GO", 400, 700),
    # Swift joins rs/go rather than taking the default pair (#728) — a DECIDED
    # value, not an omission. Same rationale: a compiled, type-dense language
    # packs more meaning per line than shell or prose and turns over harder when
    # long. Swift's verbosity (long API names, trailing closures) argues the
    # other way, but that inflates line COUNT without inflating the units-per-
    # file the threshold is a proxy for.
    "swift": ("REVIEW_LOC_WARN_SWIFT", "REVIEW_LOC_HIGH_SWIFT", 400, 700),
}


def thresholds_for(lang: str) -> tuple[int, int]:
    """The (warning, high) production-LOC pair for LANG.

    Review-lens defaults are deliberately LOOSER than the audit lens
    (check-decomposition ships 300/500): an audit sweeps a whole repo and can
    afford to nag, a per-PR gate cannot. See thresholds.yml § review_size_thresholds.
    """
    warn = _int_env("REVIEW_LOC_WARN", 500)
    high = _int_env("REVIEW_LOC_HIGH", 800)
    spec = PER_LANG_THRESHOLDS.get(lang)
    if spec is not None:
        warn_var, high_var, warn_def, high_def = spec
        warn = _int_env(warn_var, warn_def)
        high = _int_env(high_var, high_def)
    return warn, high


# UNIT NAMES ARE CURRENTLY UNREACHABLE IN THIS LENS (#730). `find_units` above is
# shared verbatim with check-decomposition, so a markdown unit is now named by
# `md_slug(text) or "section"` rather than the hardcoded "section" this file used
# to carry. That fork was real but LATENT: nothing here surfaces a unit *name* —
# `decline_reason` and every seam row below read `m["units"]`, a COUNT — so the
# unification changes no output today, which is why the differential over a
# markdown fixture stays byte-identical.
#
# Recorded as unreachable rather than given a test that cannot fail. What would
# make it live: any seam row in this lens that names its markdown sections (the
# direction #725's unified split shape and #729's bundle guidance move toward).
# At that moment the two lenses would have named the same heading differently —
# which is the bug this unification pre-empts. The reachable half (md_slug's own
# slugging rules) IS fixtured, in tests/validate-python-ports.sh.
def decline_reason(path: str, lines: list[str], m: dict) -> str:
    """WHY a long file was not flagged as splittable.

    A decline is a RESULT, not a silence — silence is indistinguishable from
    'not examined', and the recorded reason is what a reviewer cites when
    accepting the length. Reasons are reused verbatim from
    check-decomposition/contract.md so a decline reads identically in both lenses.
    """
    # Ahead of `generated` on purpose (#726) — see the matching order in
    # check-decomposition/patterns.py. A .d.ts is often ALSO banner-marked as
    # generated, and "type declaration file" is the more specific fact.
    if is_decl_file(path):
        return "type declaration file — no runtime units to extract"
    for line in lines[:20]:
        if GENERATED_RE.search(line):
            return "generated file — regenerate rather than split"
    if m["units"] <= _int_env("REVIEW_COHESIVE_MAX_UNITS", 2):
        return "single cohesive unit — no internal seam to cut"
    if m["comment_pct"] >= 50:
        return "majority prose/comment — length is documentation, not logic"
    return "no low-coupling seam found — units are mutually referential"


def numstat_path(field: str) -> str:
    """The POST-rename path from a `git diff --numstat` path field.

    git does not print a plain path for a renamed file — it prints the rename in
    one of two shapes, and neither matches what `git diff --name-only` puts in
    the caller's file list:

        old.py => new.py          (whole path changed)
        a/{x => y}/f.py           (one path segment changed)

    Left unresolved, the sidecar is keyed by that literal arrow string, the
    lookup for the real path misses, and the file's added-count silently reads 0
    — so a renamed file can never be reported as crossing a threshold no matter
    how much the diff added to it. A rename plus a large addition is exactly when
    the size lens is worth having, and it was the one case guaranteed to be quiet.
    """
    if "=>" not in field:
        return field
    start = field.find("{")
    if start != -1:
        end = field.find("}", start)
        if end != -1:
            inner = field[start + 1 : end]
            after = inner.split("=>", 1)[1].strip() if "=>" in inner else inner
            # An empty side means the segment was dropped entirely
            # (`a/{x => }/f.py`), which collapses the duplicated separator.
            joined = field[:start] + after + field[end + 1 :]
            return joined.replace("//", "/")
    return field.split("=>", 1)[1].strip()


def read_numstat(path: str) -> dict[str, int]:
    """Added-line counts per file from a `git diff --numstat` sidecar.

    Binary files render as `-` in numstat; those rows are skipped rather than
    crashing. A missing/unreadable sidecar yields {} — which the caller treats as
    'no growth signal', NOT as 'no growth'.
    """
    counts: dict[str, int] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for row in fh:
                parts = row.rstrip("\n").split("\t")
                if len(parts) < 3:
                    continue
                added, _deleted, name = parts[0], parts[1], parts[2]
                try:
                    counts[numstat_path(name)] = int(added)
                except ValueError:
                    continue
    except OSError:
        return {}
    return counts


def scan_prose(
    path: str,
    lines: list[str],
    m: dict,
    spec: tuple[int, int, str, str],
    added: int,
    have_growth: bool,
    min_added: int,
) -> None:
    """Emit the size row for a CLASSIFIED prose file — an agent definition, a
    SKILL.md, a companion, a CLAUDE.md, a memory index/concept, a docs page
    (#724).

    Thresholds and file-type label come from the shared `bloat_spec`, so this
    lens and the audit lens can never disagree about what the file is. What
    stays this lens's own is the DISPOSITION: the audit lens grades a bloat row
    flat HIGH/MEDIUM on size alone, which for a per-PR gate would make a
    one-line touch to a pre-existing 580-line agent file blocking — precisely
    the outcome #695 AC4 exists to prevent, on the file type most likely to be
    brushed against. So the same four-way growth grading the LOC path uses
    applies here, and only `crossed`/`material` are blocking-eligible.

    MEASURED ON TOTAL LINES, matching the audit lens (#701): nothing is
    excluded, because these files are loaded WHOLE into context and every line
    is real cost.
    """
    b_warn, b_high, ftype, category = spec
    total = m["total"]
    if total <= b_warn:
        return

    # PRIOR IS EXACT HERE, not the approximation the production-LOC path needs.
    # That path subtracts raw insertions from a count that excludes blanks and
    # comments, over-subtracts, and needs a clamp to stop a whitespace-heavy
    # reformat faking a threshold crossing. This budget already counts every
    # line, and numstat already counts every inserted line, so the two are in
    # the same unit and the subtraction is the real pre-diff size. The clamp's
    # absence is deliberate, not an oversight.
    prior = max(0, total - added) if have_growth else total
    crossed = have_growth and prior <= b_warn
    material = have_growth and added >= min_added

    band = "high" if total > b_high else "warning"
    limit = b_high if total > b_high else b_warn

    if crossed:
        certainty = "HIGH" if total > b_high else "MEDIUM"
        evidence = (
            f"{ftype} exceeds {band} threshold: {total} lines (>{limit}); this "
            f"diff added {added} lines and pushed it over the {b_warn} budget"
        )
    elif material:
        certainty = "MEDIUM"
        evidence = (
            f"{ftype} exceeds {band} threshold: {total} lines (>{limit}); "
            f"already over before this diff, which added {added} more lines"
        )
    elif have_growth:
        certainty = "LOW"
        evidence = (
            f"{ftype} exceeds {band} threshold: {total} lines (>{limit}); "
            f"pre-existing size, this diff added only {added} lines — "
            f"informational, not this PR's debt"
        )
    else:
        certainty = "LOW"
        evidence = (
            f"{ftype} exceeds {band} threshold: {total} lines (>{limit}); no "
            f"diff growth data supplied — informational only"
        )

    emit(path, 1, category, evidence, certainty)

    # Prose splits by progressive disclosure, never by a line range. Emitted
    # only for the dispositions a reviewer should act on, mirroring the seam
    # rule on the LOC path — a decline row would be noise on a file whose
    # length this diff did not meaningfully change.
    if not (crossed or material):
        return

    # A memory bundle takes the BUNDLE-SHAPED seam and the generic markdown one
    # is SUPPRESSED (#729) — one seam verdict per file, the same one-verdict move
    # #701 made for size. The generic row is not merely vaguer here, it is wrong:
    # an index splits by TOPIC CLUSTER and a concept by extracting its second
    # lesson, and the generic row silently drops the anti-orphan clause that
    # prevents #697's written-but-never-recallable loss.
    #
    # Checked FIRST, which is what gives the bundle arm its precedence over every
    # other prose type — a `docs/` or `agents/` directory nested inside the
    # bundle still gets bundle rules, matching the audit lens's ordering (#700).
    #
    # Rows come from the shared `bundle-seam-py` region, so the two lenses cannot
    # disagree about the shape. The DISPOSITION is still this lens's own: the
    # audit lens's LOW `declined:` rows are dropped, because "this file cannot be
    # split" is backlog information, not something a PR reviewer can act on.
    kind = bundle_kind(path)
    if kind:
        for category, evidence, certainty in bundle_seam_rows(path, lines, kind):
            if certainty == "LOW":
                continue
            emit(path, 1, category, evidence, certainty)
        return

    emit(
        path,
        1,
        "decomposition-seam",
        f"split shape for {ftype}: {split_shape('md')}",
        "MEDIUM",
    )


def scan_file(path: str, lines: list[str], added: int, have_growth: bool) -> None:
    """Emit sizing rows for one changed file.

    The growth disposition (AC4) is the whole point of the review lens:

      * crossed a threshold BECAUSE of this diff  -> MEDIUM/HIGH, actionable
      * already over, material growth             -> MEDIUM
      * already over, trivial growth              -> LOW, informational only
      * no growth signal at all                   -> LOW, informational only

    Only the first two are ever blocking-eligible. A one-line touch to a
    pre-existing oversized file CANNOT produce a blocking row, which is the
    property tests/validate-sizing-scanner.sh pins.
    """
    lang = lang_of(path)
    units = find_units(lines, lang)
    m = measure(lines, lang, units, is_test_file(path))
    warn, high = thresholds_for(lang)
    production = m["production"]
    min_added = _int_env("REVIEW_GROWTH_MIN_ADDED", 50)

    # --- Classified prose: its own budget, never the code one (#724/#701) ----
    # Checked BEFORE the production-LOC early return below, which would
    # otherwise swallow the whole branch: a 580-line agent definition measures
    # 501 production LOC, under the generic md warning of 700, so it returns
    # here and the file is never classified at all. That early return IS the
    # defect #724 reports, seen from the inside.
    #
    # EXACTLY ONE size verdict per file, exactly as the audit lens does it
    # (#701): a spec means "this file type has its own budget", so the generic
    # file-length row is skipped rather than emitted alongside.
    spec = bloat_spec(path)
    if spec is not None:
        scan_prose(path, lines, m, spec, added, have_growth, min_added)
        return

    if production <= warn:
        return

    # Production LOC before this diff, approximated by removing the added lines.
    #
    # THE APPROXIMATION ERRS LOW, NOT HIGH. numstat counts RAW insertions —
    # blanks and comments included — while `production` excludes them, so
    # subtracting one from the other over-subtracts and `prior` is a LOWER bound
    # on the true pre-diff size. (An earlier comment here claimed the opposite
    # and reasoned that erring high fails toward the quiet disposition; it fails
    # toward the LOUD one.) A reformat bundled with a small real change — 900
    # blank lines and 5 production lines added to an already-851-LOC file —
    # drove `prior` negative, satisfied `prior <= warn`, and produced a HIGH
    # "this diff pushed it over" on a file that was far over the threshold to
    # begin with: the loudest possible disposition for exactly the case AC4
    # exists to keep quiet.
    #
    # So `crossed` is CLAMPED: the added count cannot exceed the file's total
    # non-production content, because those lines had to go somewhere. `added`
    # minus the blanks/comments/test lines present is a floor on how many of the
    # insertions were production; anything above that floor is what the diff
    # genuinely contributed to `production`.
    #
    # For the 900-blank reformat: non_production is 900, so at most 5 of the 905
    # insertions were production, `prior` lands at 851 — the real value — and the
    # row correctly takes the quiet `material` path instead of claiming a HIGH
    # crossing. For an ordinary diff, where insertions are mostly production,
    # non_production is small and the clamp changes nothing.
    #
    # `prior` also floors at 0: a negative value can never describe a real file.
    non_production = m["total"] - production
    added_production = max(0, added - non_production)
    prior = max(0, production - added_production) if have_growth else production
    crossed = have_growth and prior <= warn
    material = have_growth and added >= min_added

    # Byte-identical to the `metrics` sprintf in the shared:loc-measure-awk
    # region, so the two impls' evidence strings agree by construction.
    metrics = (
        f"{m['total']} total, {m['comment']} comment ({m['comment_pct']}%), "
        f"{m['blank']} blank, {m['test_excluded']} test-excluded, "
        f"max nesting {m['max_depth']}, {m['units']} top-level units"
    )
    band = "high" if production > high else "warning"
    limit = high if production > high else warn

    if crossed:
        certainty = "HIGH" if production > high else "MEDIUM"
        evidence = (
            f"{production} production LOC (>{limit} {band}); this diff added "
            f"{added} lines and pushed it over the {warn} review threshold; {metrics}"
        )
    elif material:
        certainty = "MEDIUM"
        evidence = (
            f"{production} production LOC (>{limit} {band}); already over before "
            f"this diff, which added {added} more lines; {metrics}"
        )
    elif have_growth:
        certainty = "LOW"
        evidence = (
            f"{production} production LOC (>{limit} {band}); pre-existing size, "
            f"this diff added only {added} lines — informational, not this PR's "
            f"debt; {metrics}"
        )
    else:
        certainty = "LOW"
        evidence = (
            f"{production} production LOC (>{limit} {band}); no diff growth data "
            f"supplied — informational only; {metrics}"
        )

    emit(path, 1, "file-length", evidence, certainty)

    # The split SHAPE, so the finding names a concrete destination rather than
    # bare advice. Only for the dispositions a reviewer should act on.
    #
    # NO `and lang` GUARD. A file whose extension has no segmenter (.rb, .java,
    # .c, .cpp, .kt — scanned, since none are in SKIP_EXTS) yields lang == "",
    # and gating on it dropped BOTH arms: the first was false for want of a
    # language and the second false for want of a quiet disposition, so an
    # actionable over-threshold file emitted a file-length row and NO seam row —
    # silently withholding from the review dimension the one thing it consumes.
    # The generic fallback is weaker advice than a language-shaped one but it is
    # a real destination, and every blocking-eligible file now yields exactly one
    # seam row.
    # `and not is_decl_file(path)` (#726): a .d.ts has no runtime units to
    # extract, so a shape row would tell the reviewer to build a types/ dir out
    # of a file with nothing to move. It takes the decline branch instead, where
    # decline_reason names the declaration file specifically. This mirrors the
    # audit lens, which reaches the same outcome through `seams == 0` — the two
    # lenses gate on different quantities (growth vs seams), so the suppression
    # has to be stated in each rather than inherited.
    if (crossed or material) and not is_decl_file(path):
        shape = split_shape(lang)
        label = lang if lang else "this file"
        emit(
            path,
            1,
            "decomposition-seam",
            f"split shape for {label}: {shape}",
            "MEDIUM",
        )
    else:
        emit(
            path,
            1,
            "decomposition-seam",
            f"declined: {decline_reason(path, lines, m)} ({production} production LOC, "
            f"{m['units']} top-level units)",
            "LOW",
        )


def measure_record(path: str, lines: list[str]) -> str:
    """One TAB-separated metrics row for PATH — the MEASURE-MODE contract.

    This exists so the plan lens (plan-lens.{py,sh}, #756) can reuse this lens's
    LOC engine instead of carrying a fourth hand-copy of the counting rules. The
    audit lens and this one are already pinned byte-for-byte through the
    `# >>> shared:loc-*` sentinel regions; a third scanner re-deriving the same
    arithmetic is exactly what #663 was filed to kill, and a sentinel region can
    only pin text it can see — it cannot stop a NEW file from computing
    production LOC its own way.

    So measure mode is a SEAM, not a copy: `sizing --measure` answers "how big is
    this file, and by which budget is it judged", and the plan lens supplies only
    the projection arithmetic on top. The row is deliberately flat TSV rather
    than JSON so the bash fallback can emit the identical record from awk.

    Fields (13):
      path total production units comment_pct generated lang
      loc_warn loc_high b_warn b_high b_type b_cat

    `b_*` are empty/0 for a file the prose classifier does not claim, which is
    the signal to size it by production LOC instead of total lines.
    """
    lang = lang_of(path)
    units = find_units(lines, lang)
    m = measure(lines, lang, units, is_test_file(path))
    warn, high = thresholds_for(lang)
    spec = bloat_spec(path)
    b_warn, b_high, b_type, b_cat = spec if spec is not None else (0, 0, "", "")
    generated = 1 if any(GENERATED_RE.search(ln) for ln in lines[:20]) else 0
    return "\t".join(
        str(f)
        for f in (
            path,
            m["total"],
            m["production"],
            m["units"],
            m["comment_pct"],
            generated,
            lang,
            warn,
            high,
            b_warn,
            b_high,
            b_type,
            b_cat,
        )
    )


def main(argv: list[str]) -> int:
    # Measure mode is opt-in and positional-first, so the default review-lens
    # invocation is byte-for-byte the command it always was (#756 AC6).
    measure_only = len(argv) > 1 and argv[1] == "--measure"
    if measure_only:
        argv = [argv[0]] + argv[2:]

    if len(argv) < 2:
        sys.stderr.write("Usage: sizing.py [--measure] <file-list> [numstat-file]\n")
        return 1
    file_list = argv[1]
    if not os.path.isfile(file_list):
        sys.stderr.write(f"Error: file list not found: {file_list}\n")
        return 1

    growth = read_numstat(argv[2]) if len(argv) > 2 else {}
    have_growth = bool(growth)

    with open(file_list, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            path = raw.rstrip("\n")
            if not path or not os.path.isfile(path):
                continue
            low = path.lower()
            if (
                low.endswith(SKIP_EXTS)
                or low.endswith("lock.json")
                or low.endswith("go.sum")
            ):
                continue
            try:
                with open(path, encoding="utf-8", errors="replace") as src:
                    lines = src.read().split("\n")
            except OSError:
                continue
            if lines and lines[-1] == "":
                lines.pop()
            if measure_only:
                sys.stdout.write(measure_record(path, lines) + "\n")
            else:
                scan_file(path, lines, growth.get(path, 0), have_growth)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
