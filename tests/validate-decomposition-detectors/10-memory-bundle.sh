# shellcheck shell=bash
# Memory-bundle classification and guidance (#700) — detector tests (#760 split).
#
# A memory bundle is never code-sized: its index and concept files carry their
# own budgets under a configurable root. Split guidance is bundle-shaped too —
# an index splits by TOPIC CLUSTER, a concept split is anti-orphan. The
# reachability arm pins #578: a gitignored bundle file is still classified
# ([[explicit-path-still-honors-gitignore]]).
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Memory-bundle classification (#700).
#
# Before #700, `.claude/memory/**` matched no bloat_spec() arm and fell through
# to the CODE thresholds (DECOMP_LOC_WARN/HIGH, production LOC) — prose sized by
# a rule written for source, silently. These cases pin the bundle as a
# first-class file type with index/concept budgets.
#
# BASE_ENV pins DECOMP_LOC_WARN=5, so every fixture here is far over the code
# threshold. That is what makes the "file-length silent" assertion sharp rather
# than vacuous: pre-fix it fired on all of them.
# ============================================================================
test_memory_bundle_bloat() {
    local d f list

    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # --- index arm ---------------------------------------------------------
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# Index" "" "## Golem" "- a" "" "## Review" "- b" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: index over high threshold flagged" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_fires "$list" ai-file-bloat "memory index exceeds warning threshold" \
        "memory: index over warning threshold flagged" \
        MEMORY_INDEX_WARN=3 MEMORY_INDEX_HIGH=99
    assert_silent "$list" ai-file-bloat \
        "memory: index under thresholds is silent" \
        MEMORY_INDEX_WARN=50 MEMORY_INDEX_HIGH=99

    # THE REGRESSION GUARD: a bundle file is NEVER judged by the code
    # thresholds. BASE_ENV's DECOMP_LOC_WARN=5 is far below this file's size,
    # so pre-fix this assertion failed.
    assert_silent "$list" file-length \
        "memory: index is never reported against DECOMP_LOC_* code thresholds" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_silent "$list" file-length \
        "memory: index under its own budget is still not code-sized" \
        MEMORY_INDEX_WARN=50 MEMORY_INDEX_HIGH=99

    # --- concept arm (a DIFFERENT budget family from index) ----------------
    f="$d/.claude/memory/some-lesson.md"
    command printf '%s\n' "# Lesson" "" "## First" "text" "" "## Second" "text" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory concept exceeds high threshold" \
        "memory: concept over high threshold flagged" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    assert_silent "$list" file-length \
        "memory: concept is never reported against DECOMP_LOC_* code thresholds" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # The discriminator is real: index env vars do NOT move a concept file.
    assert_silent "$list" ai-file-bloat \
        "memory: concept ignores the index budget (the two arms are distinct)" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3 \
        MEMORY_CONCEPT_WARN=99 MEMORY_CONCEPT_HIGH=99
    # ...and symmetrically, concept env vars do not move an index file.
    assert_silent "$(list_of "$d/.claude/memory/MEMORY.md")" ai-file-bloat \
        "memory: index ignores the concept budget" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3 \
        MEMORY_INDEX_WARN=99 MEMORY_INDEX_HIGH=99

    # index-*.md is an index, not a concept (the sub-index naming this repo uses).
    f="$d/.claude/memory/index-golem.md"
    command printf '%s\n' "# Golem" "" "## A" "x" "" "## B" "y" >"$f"
    assert_fires "$(list_of "$f")" ai-file-bloat "memory index exceeds high threshold" \
        "memory: index-*.md classifies as index, not concept" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3 \
        MEMORY_CONCEPT_WARN=99 MEMORY_CONCEPT_HIGH=99

    # --- non-markdown inside a bundle is CODE, not bundle prose ------------
    # A .py in the bundle keeps the code thresholds — bundle classification is
    # about prose, and treating a script as prose would be the mirror defect.
    f="$d/.claude/memory/helper.py"
    command printf '%s\n' "def a(x):" "    return x" "" "def b(x):" "    return x" \
        "" "def c(x):" "    return x" >"$f"
    assert_fires "$(list_of "$f")" file-length "production LOC" \
        "memory: a .py inside the bundle is still code-sized"

    # --- configurable root -------------------------------------------------
    # A bundle somewhere else entirely classifies when the root points at it.
    d="$(fresh_dir)"
    command mkdir -p "$d/knowledge"
    f="$d/knowledge/MEMORY.md"
    command printf '%s\n' "# Index" "" "## A" "- a" "" "## B" "- b" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: bundle root is configurable, not hardcoded" \
        MEMORY_BUNDLE_ROOT=knowledge MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    # Every spelling of the same root must decide alike — an unnormalized root
    # misses the glob, falls back to the code thresholds, and still exits 0.
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: trailing-slash root normalizes to the same decision" \
        MEMORY_BUNDLE_ROOT=knowledge/ MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: leading-./ root normalizes to the same decision" \
        MEMORY_BUNDLE_ROOT=./knowledge MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3

    # A root carrying GLOB METACHARACTERS must be matched LITERALLY, and both
    # impls must agree. Python matched it with fnmatch (which reads `[x]` as a
    # character class and misses) while bash `case` matches a QUOTED expansion
    # literally (and hit) — so the same file classified in one impl and not the
    # other, silently, at exit 0. assert_fires runs BOTH impls, so it is the
    # parity assertion as well as the behavior one.
    d="$(fresh_dir)"
    command mkdir -p "$d/weird[x]root"
    f="$d/weird[x]root/MEMORY.md"
    command printf '%s\n' "# I" "" "## A" "- a" "" "## B" "- b" >"$f"
    assert_fires "$(list_of "$f")" ai-file-bloat "memory index exceeds high threshold" \
        "memory: a root with glob metacharacters matches literally in BOTH impls" \
        "MEMORY_BUNDLE_ROOT=weird[x]root" MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3

    # --- no bundle configured: no classification, NO error ------------------
    # An empty root disables memory classification entirely. The file then
    # takes the ordinary code path (it is no longer a bundle file at all), and
    # the scan still succeeds.
    #
    # THE FIXTURE MUST SIT AT THE DEFAULT ROOT. An earlier draft reused the
    # `knowledge/` fixture above, which is only ever a bundle file when
    # MEMORY_BUNDLE_ROOT=knowledge is passed explicitly — so with an empty root
    # it was never going to be classified whether the disable path worked or
    # not, and the assertion passed either way. Proven: making an empty root
    # fall back to the default instead of disabling left the suite GREEN.
    # A file UNDER `.claude/memory` is what makes the silence mean something:
    # it WOULD be classified with the default root in effect, so silence here
    # can only come from the disable actually firing.
    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# I" "" "## A" "- a" "" "## B" "- b" >"$f"
    list="$(list_of "$f")"
    # Control: with the DEFAULT root this same file IS classified. Without this
    # the silence below could come from the fixture rather than from the disable.
    assert_fires "$list" ai-file-bloat "memory index exceeds high threshold" \
        "memory: the empty-root fixture IS classified under the default root" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_silent "$list" ai-file-bloat \
        "memory: empty root disables memory classification" \
        MEMORY_BUNDLE_ROOT= MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    local rc=0
    /usr/bin/env MEMORY_BUNDLE_ROOT= PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SH" "$list" \
        >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "memory: no bundle configured exits 0, not an error"

    # A bundle root NESTED below the tree root — the second match arm
    # (`*/root/*` in bash, the `"/" + root + "/" in path` disjunct in python).
    # Every root fixture above puts the root at the START of the path, so that
    # arm had no coverage and a "simplification" to prefix-only would not fail.
    d="$(fresh_dir)"
    command mkdir -p "$d/proj/sub/.claude/memory"
    f="$d/proj/sub/.claude/memory/MEMORY.md"
    command printf '%s\n' "# I" "" "## A" "- a" "" "## B" "- b" >"$f"
    assert_fires "$(list_of "$f")" ai-file-bloat "memory index exceeds high threshold" \
        "memory: a bundle root nested below the tree root still classifies" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3

    # --- healthy bundle produces ZERO findings ------------------------------
    # Realistic sizes under the shipped defaults; nothing at all is emitted.
    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# Index" "" "## Topic" "- [a](a.md) — hook" >"$f"
    command printf '%s\n' "# Lesson" "" "The lesson." >"$d/.claude/memory/a.md"
    list="$(list_of "$f" "$d/.claude/memory/a.md")"
    assert_output_empty "$(/usr/bin/env PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$SH" "$list" 2>/dev/null)" \
        "memory: healthy bundle produces zero findings (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(python3 "$PY" "$list" 2>/dev/null)" \
            "memory: healthy bundle produces zero findings (python)"
    fi
}

# ============================================================================
# Memory-bundle split guidance (#700) — a bundle splits by TOPIC CLUSTER (index)
# or by extracting a second lesson WITH its index line (concept). The generic
# markdown heading-cluster seam is suppressed: a `seam <n>-<n>:` row would be
# actively wrong guidance for a bundle.
# ============================================================================
test_memory_split_guidance() {
    local d f list

    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # --- index: topic clusters, NOT line ranges -----------------------------
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "# Index" "" "## Golem" "- a" "" "## Review" "- b" \
        "" "## Release" "- c" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "index split: 3 topic clusters" \
        "memory: index guidance names topic clusters" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    assert_fires "$list" decomposition-seam "golem, review, release" \
        "memory: index guidance names the actual cluster topics" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    # The AC, asserted negatively: no line-range seam for a bundle file. The
    # markdown segmenter WOULD produce one here without the suppression.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
        "seam " "memory: index guidance carries no line-range seam (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
            "seam " "memory: index guidance carries no line-range seam (python)"
    fi

    # Topic clusters come from the `##` sections, NOT the shallowest-heading
    # top-level units — which for a `# Title` + `## topics` file is the lone
    # title. Keying off those would make every index decline. This assertion is
    # what pins that: it requires 3 clusters from a file with ONE `#`.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
        "no topic clusters" "memory: a titled index still finds its ## clusters (bash)"

    # --- concept: extraction ALWAYS carries the index-line requirement -------
    f="$d/.claude/memory/two-lessons.md"
    command printf '%s\n' "# Lessons" "" "## First Thing" "text" "" \
        "## Second Thing" "text" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "concept split: extract second_thing" \
        "memory: concept guidance extracts the second lesson" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # THE ANTI-ORPHAN AC: a split that would leave the extracted half unindexed
    # must be flagged, never proposed. The requirement is unconditional.
    assert_fires "$list" decomposition-seam "AND add its index line" \
        "memory: concept split requires the extracted half get an index line" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    assert_fires "$list" decomposition-seam "orphan" \
        "memory: concept guidance names the orphan failure it prevents" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # The extraction target sits under the bundle root, not a hardcoded one.
    # For a FLAT bundle the source file's own directory IS the root, so #713's
    # fix leaves the relative shape of this case unmoved — it is now derived
    # rather than assumed. `$d`-anchored like every other target assertion here
    # (`> $d/mod/parse.py`): a target is spelled the way its source was, which
    # is what makes it a path the reader can actually act on.
    assert_fires "$list" decomposition-seam "to $d/.claude/memory/second_thing.md" \
        "memory: extraction target sits beside a flat concept, in the bundle root" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3

    # --- guidance is gated on being OVER budget -----------------------------
    # A bundle file inside its budget gets no guidance at all — guidance is a
    # consequence of the size verdict, not an unconditional annotation.
    assert_silent "$list" decomposition-seam \
        "memory: an in-budget concept gets no split guidance" \
        MEMORY_CONCEPT_WARN=99 MEMORY_CONCEPT_HIGH=99

    # --- NESTED concept: the target is a SIBLING, not a root refugee (#713) --
    # bundle_kind() supports a concept nested below the root (its `*/root/*`
    # arm), and the guidance used to anchor the target at the bundle root
    # unconditionally — silently dropping the `topics/` segment, which followed
    # literally moves the extracted lesson OUT of its subdirectory. Both impls
    # shared that defect, so the same-output parity gate could never catch it;
    # assert_fires runs both, making this the parity assertion as well.
    f="$d/.claude/memory/topics/two-lessons.md"
    command mkdir -p "$d/.claude/memory/topics"
    command printf '%s\n' "# Lessons" "" "## First Thing" "text" "" \
        "## Second Thing" "text" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "to $d/.claude/memory/topics/second_thing.md" \
        "memory: a nested concept extracts beside itself, not to the bundle root" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    # Asserted negatively too: the root-anchored target must be GONE, not merely
    # accompanied. The positive assertion above is a SUBSTRING check, and
    # `.../topics/second_thing.md` does not contain `.../memory/second_thing.md`
    # — but an emit that named both targets would still satisfy it. This pins
    # that the wrong one is absent rather than merely outvoted.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)" \
        "to $d/.claude/memory/second_thing.md" \
        "memory: nested concept does not propose the root-anchored target (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)" \
            "to $d/.claude/memory/second_thing.md" \
            "memory: nested concept does not propose the root-anchored target (python)"
    fi

    # --- unsplittable bundle files decline with a reason --------------------
    # One lesson, one section: nothing to extract. A decline is a RESULT, not
    # silence (the same contract the code path's reasoned decline carries).
    f="$d/.claude/memory/single.md"
    command printf '%s\n' "# One" "" "text" "more" >"$f"
    assert_fires "$(list_of "$f")" decomposition-seam "declined: single lesson" \
        "memory: a single-lesson concept declines with a reason" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3

    # The INDEX decline arm — the fourth of the bundle branch's four outcomes,
    # and the one an index-kind fixture is needed for: an over-budget index with
    # fewer than 2 topic clusters has nothing to split along. Without this the
    # arm had no assertion in either the gate or the coverage corpus, which is
    # the "rule with zero failing tests" shape the mutation round exists to find.
    f="$d/.claude/memory/index-flat.md"
    command printf '%s\n' "# Flat" "" "one" "two" "three" >"$f"
    assert_fires "$(list_of "$f")" decomposition-seam "declined: index has no topic clusters" \
        "memory: an index with no topic clusters declines with a reason" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
}

# ============================================================================
# Reachability (#578) — "explicit path still honors gitignore".
#
# rumdl/ruff re-apply .gitignore when handed a DIRECTORY, which is why
# tests/lint-markdown.sh exists. This scanner is structurally different: it
# reads an explicit newline file LIST and never walks the tree itself, so a
# gitignored bundle is reachable. #700 asked for that to be PROVEN by fixture
# rather than assumed — a consuming repo may well gitignore part of its bundle
# (this one gitignores .claude/memory/tmp/).
#
# The residual risk is therefore in LIST CONSTRUCTION (checker.md's manifest),
# not in the scanner — this case pins the scanner half so a future change that
# made it walk the tree would fail here.
# ============================================================================
test_memory_gitignored_reachability() {
    local d f list
    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # A real git repo whose .gitignore excludes the whole bundle.
    command git -C "$d" init -q 2>/dev/null || skip_test "git unavailable"
    command printf '%s\n' ".claude/memory/" >"$d/.gitignore"

    f="$d/.claude/memory/ignored-lesson.md"
    command printf '%s\n' "# Lesson" "" "## A" "x" "" "## B" "y" >"$f"

    # Precondition — the fixture is genuinely gitignored. Without this the case
    # would pass vacuously on a tree where the ignore never applied.
    local rc=0
    command git -C "$d" check-ignore -q ".claude/memory/ignored-lesson.md" || rc=$?
    assert_exit 0 "$rc" "reachability: the fixture bundle really is gitignored"

    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "memory concept exceeds high threshold" \
        "reachability: a gitignored bundle file is still classified (#578)" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
}
