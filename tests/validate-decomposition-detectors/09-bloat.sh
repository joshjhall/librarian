# shellcheck shell=bash
# Size verdicts and bloat categories — detector tests (issue #760 split).
#
# The per-type prose budgets and the whole-file size arms: ai-file-bloat (with
# the #494 flat-vs-nested agent globs), companion_md (#589), doc-file-bloat,
# the #701 exclusivity rule that a classified file gets its type budget XOR
# file-length, god-module (never size alone), and the skip/threshold arms.
#
# ai-file-bloat and doc-file-bloat were MOVED here from
# tests/validate-checker-detectors.sh by #663 when those categories moved off
# check-ai-config — including the #222 "docs bloat does not emit under
# ai-file-bloat" counter. Moving them preserved the coverage across the
# ownership change instead of deleting it.
#
# Sourced by tests/validate-decomposition-detectors.sh, which defines PY / SH /
# REAL_BASH and sources tests/lib/decomposition-sandbox.sh (the emit_rows /
# assert_fires / assert_silent / fresh_dir / list_of drivers) BEFORE this file.
# This fragment only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_fragment_test list.

# ============================================================================
# ai-file-bloat — MOVED from validate-checker-detectors.sh by #663.
# Thresholds tuned down via env so a tiny fixture trips them.
# ============================================================================
test_ai_file_bloat() {
    local d f list
    d="$(fresh_dir)"

    # 5-line CLAUDE.md with HIGH driven to 3 -> exceeds high (HIGH).
    f="$d/CLAUDE.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "exceeds high threshold" \
        "ai-file-bloat: CLAUDE.md over high threshold flagged" \
        CLAUDE_MD_WARN=2 CLAUDE_MD_HIGH=3

    # Same file, WARN=3 HIGH=99 -> warning arm only (MEDIUM).
    assert_fires "$list" ai-file-bloat "exceeds warning threshold" \
        "ai-file-bloat: CLAUDE.md over warning threshold flagged" \
        CLAUDE_MD_WARN=3 CLAUDE_MD_HIGH=99

    # Counter: comfortably under both thresholds -> silent.
    assert_silent "$list" ai-file-bloat \
        "ai-file-bloat: CLAUDE.md under thresholds is silent" \
        CLAUDE_MD_WARN=50 CLAUDE_MD_HIGH=99

    # SKILL.md threshold arm (separate env family).
    command mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "---" "description: d" "---" "## Workflow" "a" "b" "c" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "skill definition exceeds high threshold" \
        "ai-file-bloat: SKILL.md over high threshold flagged" \
        SKILL_WARN=2 SKILL_HIGH=3

    # Agent-definition arm — the FLAT layout agents/<name>.md (Claude Code's
    # discovery form). The bloat glob was */agents/*/*.md only, which does not
    # match a flat file, so a flat agent over threshold was silently missed (#494).
    command mkdir -p "$d/agents"
    f="$d/agents/rev.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "agent definition exceeds high threshold" \
        "ai-file-bloat: FLAT agent md over high threshold flagged (#494)" \
        AGENT_WARN=2 AGENT_HIGH=3

    # Counter: the widened glob must not OVER-fire — a flat agent comfortably
    # under threshold stays silent (mirrors the CLAUDE.md silent counter above).
    assert_silent "$list" ai-file-bloat \
        "ai-file-bloat: FLAT agent md under thresholds is silent (#494)" \
        AGENT_WARN=50 AGENT_HIGH=99

    # Agent-definition arm — the NESTED layout agents/<name>/<name>.md (a
    # harness-bearing agent's sibling md). Must still fire after the glob widened.
    command mkdir -p "$d/agents/nested"
    f="$d/agents/nested/nested.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "agent definition exceeds warning threshold" \
        "ai-file-bloat: NESTED agent md over warning threshold flagged" \
        AGENT_WARN=3 AGENT_HIGH=99
}

# ============================================================================
# companion_md (#589) — skills/<name>/<other>.md, the reference prose a SKILL.md
# loads on demand. Before this arm a companion matched NO bloat glob and fell
# through to the production-LOC CODE thresholds — sized by a rule written for
# source, on the largest prose files in the repo. Same defect #700 fixed for the
# memory bundle.
#
# THE ORDERING CASE IS THE POINT. `*/skills/*/*.md` also matches a SKILL.md, so
# the narrower SKILL.md arm must come FIRST in both impls (`case` takes the first
# match; the Python arms are sequential ifs). A fixture must therefore straddle
# the two budgets — over SKILL_HIGH but under COMPANION_HIGH — because that band
# is the ONLY place a hoisted companion arm is observable. Sized under both, or
# over both, the test passes with and without the bug.
# ============================================================================
test_companion_md_bloat() {
    local d f list
    d="$(fresh_dir)"

    command mkdir -p "$d/skills/orch"
    f="$d/skills/orch/mode-protocol.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"

    # High arm.
    assert_fires "$list" ai-file-bloat "skill companion exceeds high threshold" \
        "companion_md: companion over high threshold flagged" \
        COMPANION_WARN=2 COMPANION_HIGH=3

    # Warning arm.
    assert_fires "$list" ai-file-bloat "skill companion exceeds warning threshold" \
        "companion_md: companion over warning threshold flagged" \
        COMPANION_WARN=3 COMPANION_HIGH=99

    # Counter: under both -> silent (the arm must not over-fire).
    assert_silent "$list" ai-file-bloat \
        "companion_md: companion under thresholds is silent" \
        COMPANION_WARN=50 COMPANION_HIGH=99

    # ORDERING: a SKILL.md in the band between the two budgets must be judged as
    # a SKILL definition, never as a companion. With SKILL_HIGH=3 and
    # COMPANION_HIGH=99, a 5-line SKILL.md is over the skill budget and under the
    # companion one — so a hoisted companion arm would report nothing here.
    command mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "skill definition exceeds high threshold" \
        "companion_md: SKILL.md keeps its own tighter budget (arm ordering)" \
        SKILL_WARN=2 SKILL_HIGH=3 COMPANION_WARN=50 COMPANION_HIGH=99
    # And it must not ALSO be reported as a companion — one file, one verdict.
    assert_silent "$list" doc-file-bloat \
        "companion_md: a SKILL.md emits no doc-file-bloat row" \
        SKILL_WARN=2 SKILL_HIGH=3 COMPANION_WARN=50 COMPANION_HIGH=99
}

# ============================================================================
# doc-file-bloat — MOVED from validate-checker-detectors.sh by #663.
# */docs/*.md over DOC_WARN/DOC_HIGH; a docs file must emit doc-file-bloat and
# NOT ai-file-bloat (the #222 split).
# ============================================================================
test_doc_file_bloat() {
    local d f list
    d="$(fresh_dir)"

    command mkdir -p "$d/docs"
    f="$d/docs/guide.md"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"

    # 5-line docs file, HIGH driven to 3 -> exceeds high (HIGH), under doc-file-bloat.
    assert_fires "$list" doc-file-bloat "documentation exceeds high threshold" \
        "doc-file-bloat: docs/*.md over high threshold flagged" \
        DOC_WARN=2 DOC_HIGH=3
    # It must NOT surface under the ai-file-bloat slug (the split is the point).
    assert_silent "$list" ai-file-bloat \
        "doc-file-bloat: docs bloat does not emit under ai-file-bloat" \
        DOC_WARN=2 DOC_HIGH=3

    # Warning arm (MEDIUM).
    assert_fires "$list" doc-file-bloat "documentation exceeds warning threshold" \
        "doc-file-bloat: docs/*.md over warning threshold flagged" \
        DOC_WARN=3 DOC_HIGH=99

    # Counter: comfortably under both -> silent.
    assert_silent "$list" doc-file-bloat \
        "doc-file-bloat: docs/*.md under thresholds is silent" \
        DOC_WARN=50 DOC_HIGH=99
}

# ============================================================================
# Size-verdict exclusivity (#701) — a classified file gets its per-type budget
# and NOT the generic production-LOC file-length verdict.
#
# Before #701 both size checks ran unconditionally, so classified markdown got
# TWO rows for one problem (two categories, two different numbers), and a docs
# page comfortably UNDER its own doc_md budget was still flagged against the
# code thresholds. BASE_ENV pins DECOMP_LOC_WARN=5, so every fixture here is
# far over the code threshold — that is what makes each "file-length silent"
# assertion sharp rather than vacuous: pre-fix it fired on all of them.
# ============================================================================
test_size_verdict_exclusivity() {
    local d f list i

    # --- Classified AND over its own budget: exactly ONE row ----------------
    # Pre-fix this file emitted ai-file-bloat AND file-length together.
    d="$(fresh_dir)"
    command mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "---" "description: d" "---" "## Workflow" "a" "b" "c" >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" ai-file-bloat "skill definition exceeds high threshold" \
        "exclusivity: a classified file still gets its per-type verdict" \
        SKILL_WARN=2 SKILL_HIGH=3
    assert_silent "$list" file-length \
        "exclusivity: a classified file does NOT also get the code file-length verdict (#701)" \
        SKILL_WARN=2 SKILL_HIGH=3

    # --- Classified and UNDER its own budget: NO size row at all ------------
    # The disposition-recall-tally-613.md shape from the issue: a docs page
    # under doc_md warn that the code lens flagged anyway. Both categories must
    # be silent — the type budget is the only verdict, and it says "fine".
    command mkdir -p "$d/docs"
    f="$d/docs/tally.md"
    : >"$f"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        command printf 'Row %s of a running tally that is supposed to grow.\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_silent "$list" doc-file-bloat \
        "exclusivity: a docs page under its own budget gets no bloat row" \
        DOC_WARN=500 DOC_HIGH=800
    assert_silent "$list" file-length \
        "exclusivity: a docs page under its own budget is NOT flagged by the code lens (#701)" \
        DOC_WARN=500 DOC_HIGH=800

    # --- Unclassified files are UNAFFECTED ----------------------------------
    # The fix must narrow only the classified path. Three languages, because a
    # regression that keyed off "is markdown" rather than "is classified" would
    # still pass on a single .py fixture.
    f="$d/mid.py"
    command cat >"$f" <<'EOF'
def alpha(x):
    return x

def beta(x):
    return x

def gamma(x):
    return x
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC" \
        "exclusivity: an unclassified .py still gets file-length"

    f="$d/tool.sh"
    command cat >"$f" <<'EOF'
run_alpha() {
    do_work
}

run_beta() {
    do_work
}

run_gamma() {
    do_work
}
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC" \
        "exclusivity: an unclassified .sh still gets file-length"

    # Unclassified MARKDOWN specifically: a README is not matched by any
    # bloat_spec() arm, so the code lens remains its ONLY size lens. That is
    # the #700 case and is deliberately out of scope here — pinning it stops a
    # future widening of bloat_spec() from silently changing this file's
    # behavior without a test going red.
    f="$d/README.md"
    : >"$f"
    for i in 1 2 3 4 5 6 7 8; do
        command printf '## Section %s\n\nProse.\n\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC" \
        "exclusivity: unclassified markdown (README) keeps the code lens (#700 scope)"

    # --- Segmentation still runs on classified markdown ---------------------
    # This is about the size VERDICT, not the analysis: an oversized SKILL.md
    # must still yield a decomposition seam naming the sections to extract.
    f="$d/skills/big/SKILL.md"
    command cat >"$f" <<'EOF'
## Overview

Text.

## Install on Linux

Steps.

## Install on Mac

Steps.

## Install on Windows

Steps.
EOF
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "section install_* family (3 units," \
        "exclusivity: seam analysis still runs on classified markdown" \
        SKILL_WARN=2 SKILL_HIGH=3

    # --- The size finding still pairs with a seam-or-decline ----------------
    # `over` is now set by the BLOAT verdict, so the reasoned-decline emit must
    # still fire for a classified file with no cuttable seam. If `over` had
    # been left keyed to file-length, this row would vanish silently and
    # audit-decomposition.md's pairing contract would lose its coverage for the
    # bloat categories.
    f="$d/skills/big/SKILL.md"
    command printf '%s\n' "## Only Section" "" "One cohesive block." "" "More prose." >"$f"
    list="$(list_of "$f")"
    assert_fires "$list" decomposition-seam "declined:" \
        "exclusivity: a classified over-budget file still records a decline (over-flag pairing)" \
        SKILL_WARN=2 SKILL_HIGH=3
    # Counter: UNDER budget -> not over -> no decline row either. Pins that the
    # decline follows the verdict rather than firing on every classified file.
    assert_silent "$list" decomposition-seam \
        "exclusivity: an under-budget classified file records no decline" \
        SKILL_WARN=500 SKILL_HIGH=800
}

# ============================================================================
# god-module — size AND many units AND several concerns (never size alone)
# ============================================================================
test_god_module() {
    local d f list i
    d="$(fresh_dir)"

    # 15 units across 3 concern families -> god-module.
    f="$d/god.py"
    : >"$f"
    for i in 1 2 3 4 5; do
        command printf 'def parse_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    for i in 1 2 3 4 5; do
        command printf 'def render_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    for i in 1 2 3 4 5; do
        command printf 'def store_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_fires "$list" god-module "15 top-level units, 3 concerns" \
        "god-module: size + unit count + concern spread fires"

    # Counter: an equally LONG file with ONE concern is not a god module —
    # size alone must never be sufficient, which is the whole rule.
    f="$d/cohesive.py"
    : >"$f"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        command printf 'def parse_%s(x):\n    return x\n\n' "$i" >>"$f"
    done
    list="$(list_of "$f")"
    assert_silent "$list" god-module \
        "god-module: a long SINGLE-concern file is not a god module (size alone insufficient)"
}

# ============================================================================
# Skips and thresholds
# ============================================================================
test_skips_and_thresholds() {
    local d f list
    d="$(fresh_dir)"

    # Lock/data files are skipped wholesale regardless of size.
    f="$d/package-lock.json"
    command printf '%s\n' "l1" "l2" "l3" "l4" "l5" "l6" "l7" "l8" >"$f"
    list="$(list_of "$f")"
    assert_silent "$list" file-length "skip: a lock file is never size-reported"

    # Thresholds are genuinely project-overridable: the SAME file crosses or
    # stays under the line depending only on DECOMP_LOC_WARN.
    f="$d/mid.py"
    command cat >"$f" <<'EOF'
def a(x):
    return x

def b(x):
    return x

def c(x):
    return x
EOF
    list="$(list_of "$f")"
    assert_fires "$list" file-length "production LOC (>5 warning)" \
        "thresholds: default compact warn threshold fires"
    assert_silent "$list" file-length \
        "thresholds: raising DECOMP_LOC_WARN silences the same file" \
        DECOMP_LOC_WARN=900
}
