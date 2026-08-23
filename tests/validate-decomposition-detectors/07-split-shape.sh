# shellcheck shell=bash
# Split SHAPE (#725) — check-decomposition detector tests (issue #760 split).
#
# The audit lens names a DESTINATION, not just a span: every language arm is
# reachable and language-specific, a DECLINED file gets a reason rather than a
# destination, and memory-bundle guidance pre-empts the generic markdown advice.
#
# The bundle-precedence case is the one that had to be REBUILT after its
# mutation — see the entry point's MUTATION-VERIFIED ledger. Its headings are a
# same-family cluster on purpose; unrelated topics produce no markdown seam at
# all, so the fixture emitted nothing with OR without the suppression and proved
# nothing ([[gate-and-evidence-converge-tautology]]).
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# Split SHAPE (#725) — the audit lens names a DESTINATION, not just a span
# ============================================================================
# Before #725 the shape table lived on the review lens alone, which was
# backwards: this lens files a backlog somebody picks up weeks later, with none
# of the PR context that makes `seam 412-680` interpretable. The unified table
# is shared via `# >>> shared:split-shape-{py,awk}` and pinned against drift by
# tests/validate-shared-scanner-sync.sh; what THIS gate proves is that the audit
# lens actually CONSULTS it — a synced-but-unread table would pass that gate and
# still emit nothing here.
#
# Each arm asserts its OWN string, which pins distinctness as well as presence:
# a copy-paste leaving two languages sharing one shape would satisfy a per-arm
# "contains something" check and nothing else would notice.
test_split_shape_per_language() {
    local d f list entry ext lang expect i

    d="$(fresh_dir)"

    # ext:lang:expected-substring — one entry per shape arm. md is covered
    # separately below (its fixture needs headings, not units).
    for entry in \
        "py:py:__init__.py" \
        "js:js:sibling modules" \
        "ts:ts:types/ dir split by domain" \
        "rs:rs:mod.rs" \
        "go:go:same package" \
        "sh:sh:sourced fragment"; do
        ext="${entry%%:*}"
        lang="${entry#*:}"
        lang="${lang%%:*}"
        expect="${entry##*:}"

        f="$d/shape.$ext"
        : >"$f"
        i=0
        # A same-family cluster large enough to clear the seam floor — the shape
        # row is gated on a REAL seam, so a fixture that produced none would
        # prove nothing about the table.
        while [ "$i" -lt 6 ]; do
            case "$ext" in
                py) command printf 'def parse_%d(s):\n    return s\n\n' "$i" >>"$f" ;;
                js) command printf 'export function parseUnit%d(s) {\n  return s;\n}\n\n' "$i" >>"$f" ;;
                # A TYPE-level family, so the ts arm is reached through the
                # forms only its own segmenter matches (#726) rather than
                # through a function the js arm would have caught anyway.
                ts) command printf 'export interface ParseUnit%d { s: string }\n\n\n' "$i" >>"$f" ;;
                rs) command printf 'fn parse_%d() {\n    let _ = %d;\n}\n\n' "$i" "$i" >>"$f" ;;
                go) command printf 'func parse_%d() int {\n    return %d\n}\n\n' "$i" "$i" >>"$f" ;;
                sh) command printf 'parse_%d() {\n    echo %d\n}\n\n' "$i" "$i" >>"$f" ;;
            esac
            i=$((i + 1))
        done
        list="$(list_of "$f")"

        assert_fires "$list" decomposition-seam "split shape for ${lang}:" \
            "shape: the ${lang} arm names its language"
        assert_fires "$list" decomposition-seam "$expect" \
            "shape: the ${lang} arm gives ${lang}-shaped guidance"
    done

    # --- markdown: progressive disclosure, not a module move ----------------
    # The one arm structurally unlike its siblings, and the surface this repo
    # churns fastest (#589).
    f="$d/guide.md"
    command cat >"$f" <<'EOF'
## Install on Linux

Steps.

## Install on Mac

Steps.

## Install on Windows

Steps.
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "split shape for md: progressive disclosure" \
        "shape: markdown guidance is progressive disclosure"
    assert_fires "$list" decomposition-seam "one-line pointer" \
        "shape: markdown guidance says to leave a pointer behind"
    # Distinctness, asserted negatively: markdown must not receive a sibling
    # language's advice. A table whose arms all collapsed to one string would
    # pass every positive assertion above.
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam)" "barrel index.ts" \
        "shape: markdown does not get the JS shape (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$list" decomposition-seam)" "barrel index.ts" \
            "shape: markdown does not get the JS shape (python)"
    fi
}

# The shape row accompanies a SEAM, never a decline.
#
# The `over && seams == 0` arm emits a reasoned decline — "no low-coupling seam
# found", "single cohesive unit". A shape row beside it would contradict its own
# neighbour: build a package dir out of a file the scanner just said has nothing
# to cut. That is why the emit is gated on `seams > 0` rather than on `over`,
# and this is the fixture that pins the gate — with `over` it would still be
# green everywhere except here.
test_split_shape_not_emitted_beside_a_decline() {
    local d f list out

    d="$(fresh_dir)"
    # One long cohesive unit: over threshold, no seam, so the decline fires.
    f="$d/cohesive.py"
    command printf '%s\n' "def only(x):" >"$f"
    i=0
    while [ "$i" -lt 30 ]; do
        command printf '    x = x + %d\n' "$i" >>"$f"
        i=$((i + 1))
    done
    command printf '%s\n' "    return x" >>"$f"
    list="$(list_of "$f")"

    # Control: the decline IS firing, so the negative below cannot pass merely
    # because the file was never classified as over-threshold.
    assert_fires "$list" decomposition-seam "declined: single cohesive unit" \
        "shape: the cohesive-decline control fires"

    out="$(emit_rows sh "$list" decomposition-seam)"
    assert_not_contains "$out" "split shape for" \
        "shape: a declined file gets no shape row (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam)"
        assert_not_contains "$out" "split shape for" \
            "shape: a declined file gets no shape row (python)"
    fi
}

# BUNDLE PRECEDENCE (#725 AC4, preserving #700).
#
# A memory index/concept must keep its bundle-specific guidance and must NOT
# start receiving generic `md` shape advice as a side effect of the
# unification. An index splits by TOPIC CLUSTER and a concept by extracting its
# second lesson plus an index line — neither is "move detail to linked files".
#
# It holds by CONSTRUCTION today (the bundle branch returns before the language
# path), which is exactly why it is fixtured: an invariant nothing asserts is
# one refactor away from not holding, and its loss would be silent — a plausible
# extra row, not an error.
#
# THE HEADINGS ARE A SAME-FAMILY CLUSTER (`## Install on {Linux,Mac,Windows}`)
# AND THAT IS LOad-BEARING. A negative assertion only means something if the
# thing it forbids would otherwise appear. The obvious fixture — an index of
# unrelated `## Golem` / `## Review` / `## Release` topics — produces no
# markdown seam at all, so it emits no shape row with the suppression AND none
# without it: green either way, proving nothing
# ([[gate-and-evidence-converge-tautology]]). Verified by deleting the bundle
# early-return in both impls: with these headings the generic
# `split shape for md` row appears and this case goes red; with unrelated
# headings it stayed green.
#
# BOTH halves are asserted, per the AC: index and concept.
test_split_shape_suppressed_for_memory_bundles() {
    local d f list out

    d="$(fresh_dir)"
    command mkdir -p "$d/.claude/memory"

    # --- index half ---------------------------------------------------------
    f="$d/.claude/memory/MEMORY.md"
    command printf '%s\n' "## Install on Linux" "" "Steps for linux." "" \
        "## Install on Mac" "" "Steps for mac." "" \
        "## Install on Windows" "" "Steps for windows." >"$f"
    list="$(list_of "$f")"

    # Control: bundle guidance is present, so the negative cannot pass because
    # the file fell under budget and emitted nothing at all.
    assert_fires "$list" decomposition-seam "index split: 3 topic clusters" \
        "bundle: the index keeps its own split guidance" \
        MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3
    # The generic markdown SEAM is suppressed too (#700) — the row the shape
    # would have accompanied. Asserting both is what distinguishes "the shape is
    # suppressed" from "the seam that carries it never fired".
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)" \
        "seam 1-" "bundle: an index gets no line-range seam (bash)"

    out="$(emit_rows sh "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)"
    assert_not_contains "$out" "split shape for md" \
        "bundle: an index gets no generic md shape advice (bash)"
    assert_not_contains "$out" "progressive disclosure" \
        "bundle: an index is not told to use progressive disclosure (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam MEMORY_INDEX_WARN=2 MEMORY_INDEX_HIGH=3)"
        assert_not_contains "$out" "split shape for md" \
            "bundle: an index gets no generic md shape advice (python)"
        assert_not_contains "$out" "progressive disclosure" \
            "bundle: an index is not told to use progressive disclosure (python)"
    fi

    # --- concept half -------------------------------------------------------
    # Same-family headings for the same reason as the index above: `## Extract
    # the {First,Second} Lesson` clusters, so a lost suppression WOULD produce a
    # markdown seam plus its shape row. `extract_*` also keeps the second
    # section's slug distinct, which the concept-split assertion reads.
    f="$d/.claude/memory/two-lessons.md"
    command printf '%s\n' "## Extract One Lesson" "" "text here for one." "" \
        "## Extract Two Lesson" "" "text here for two." "" \
        "## Extract Three Lesson" "" "text here for three." >"$f"
    list="$(list_of "$f")"

    assert_fires "$list" decomposition-seam "concept split: extract extract_two_lesson" \
        "bundle: the concept keeps its own split guidance" \
        MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3
    assert_not_contains "$(emit_rows sh "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)" \
        "seam 1-" "bundle: a concept gets no line-range seam (bash)"

    out="$(emit_rows sh "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)"
    assert_not_contains "$out" "split shape for md" \
        "bundle: a concept gets no generic md shape advice (bash)"
    assert_not_contains "$out" "progressive disclosure" \
        "bundle: a concept is not told to use progressive disclosure (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        out="$(emit_rows py "$list" decomposition-seam MEMORY_CONCEPT_WARN=2 MEMORY_CONCEPT_HIGH=3)"
        assert_not_contains "$out" "split shape for md" \
            "bundle: a concept gets no generic md shape advice (python)"
        assert_not_contains "$out" "progressive disclosure" \
            "bundle: a concept is not told to use progressive disclosure (python)"
    fi
}
