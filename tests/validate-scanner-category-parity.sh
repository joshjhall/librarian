#!/usr/bin/env bash
# Source-level category-slug parity gate for patterns.sh <-> patterns.py (#189).
#
# The two existing equivalence gates compare EMITTED OUTPUT over a corpus:
#   - validate-python-ports.sh        — bash vs python over one shared fixture
#   - validate-prescan-differential.sh — the same diff over the whole repo plus
#                                        a per-category/per-language fixture lib
# Both are blind to a category slug added to only ONE impl when no input file
# happens to trigger it (a language with no example in the repo or the fixture
# library). validate-contracts.sh cross-checks slugs against each contract's
# Categories table, but UNIONS the two impls, so a one-sided slug still passes.
#
# This gate closes that gap at the SOURCE level: for every patterns.sh/patterns.py
# pair it extracts each impl's category slug set INDEPENDENTLY and fails when the
# two sets differ, printing the symmetric difference. Source-set equality here +
# output equality in the sibling gates together pin the invariant "a category in
# one impl MUST exist in the other" — enforced even with zero fixture coverage.
#
# A tool that ships only patterns.sh (no port yet) is SKIPPED, not failed —
# parity applies only where both impls exist, matching validate-python-ports.sh.
#
# Pure bash + coreutils; no node/jq. See CLAUDE.md § Runtime policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"

# Category slug literals are lowercase kebab tokens like "hardcoded-secret".
# This is the SAME shape validate-contracts.sh's extract_patterns_categories
# uses, applied here PER FILE rather than unioned across the pair.
_SLUG_RX='"[a-z][a-z0-9]+-[a-z][a-z0-9-]*"'

# category_slugs_of <file> — print the sorted, unique category slugs declared in
# one impl file (quotes stripped). Empty output for a missing file.
category_slugs_of() {
    local file="$1"
    [ -f "$file" ] || return 0
    command grep -oE "$_SLUG_RX" "$file" 2>/dev/null |
        command tr -d '"' |
        command sort -u
}

# category_parity_diff <sh_file> <py_file> — print the symmetric difference of
# the two impls' slug sets, one line per divergence:
#   only in patterns.sh: <slug>
#   only in patterns.py: <slug>
# Empty output means the sets are identical (parity holds).
category_parity_diff() {
    local sh_file="$1" py_file="$2" sh_slugs py_slugs
    sh_slugs="$(category_slugs_of "$sh_file")"
    py_slugs="$(category_slugs_of "$py_file")"
    command comm -23 \
        <(printf '%s\n' "$sh_slugs") \
        <(printf '%s\n' "$py_slugs") |
        while IFS= read -r slug; do
            [ -n "$slug" ] && printf 'only in patterns.sh: %s\n' "$slug"
        done
    command comm -13 \
        <(printf '%s\n' "$sh_slugs") \
        <(printf '%s\n' "$py_slugs") |
        while IFS= read -r slug; do
            [ -n "$slug" ] && printf 'only in patterns.py: %s\n' "$slug"
        done
}

test_suite "Source-level category-slug parity (#189)"

# --- Real pre-scan pairs under plugins/ -------------------------------------

# py_sources_for <sh_file> — every Python file that makes up the bash file's
# counterpart: the `patterns.py` entry PLUS any sibling module it was split into.
#
# A scanner's Python half is no longer necessarily ONE file (#772).
# check-decomposition's entry now imports loc_engine.py and prose_spec.py, and
# the two `*-file-bloat` slugs are emitted from prose_spec.py — so an
# entry-only read reported them as bash-only and failed a pair that is in fact
# in perfect parity. The failure was correct to fire: reading one file of a
# multi-file impl genuinely does miss slugs. The fix is to read the whole impl.
#
# Scoped to the modules the entry ACTUALLY IMPORTS from its own directory — not
# to every *.py in that directory. A directory sweep was the first attempt and
# was wrong: check-ai-config/ also holds `agnix-normalize.py`, a JSON->TSV bridge
# that is NOT part of the patterns pair, and folding its slugs in reported a
# python-only divergence on a pair that was fine.
#
# The import list is the precise boundary, and it is cheap to read because these
# scanners are flat: a sibling module is imported by bare name (their `sys.path`
# seeding reaches only their own dir), so `^from <name> import` where
# `<name>.py` sits beside the entry is exactly the set.
py_sources_for() {
    local sh="$1" dir entry mod
    dir="${sh%/*}"
    entry="${sh%patterns.sh}patterns.py"
    [ -f "$entry" ] || return 0

    printf '%s\n' "$entry"
    command grep -oE '^from [A-Za-z_][A-Za-z0-9_]* import' "$entry" 2>/dev/null |
        command awk '{ print $2 }' |
        command sort -u |
        while IFS= read -r mod; do
            [ -n "$mod" ] || continue
            [ -f "$dir/$mod.py" ] && printf '%s\n' "$dir/$mod.py"
        done
}

# sh_sources_for <sh_file> — every bash file that makes up the impl: the
# `patterns.sh` entry PLUS any sibling fragment it sources.
#
# THE EXACT MIRROR OF py_sources_for ABOVE, and it exists for the same reason
# one turn later (#991). check-okf-conformance's bash half was split when
# patterns.sh went over its production-LOC budget: slice B (the bundle graph +
# health pass) moved to bundle-graph.sh, which is where all five `memory-*`
# slugs live. An entry-only read reported them as python-only and failed a pair
# that is in perfect parity — the identical symptom #772 hit on the python side,
# arriving from the other direction.
#
# The asymmetry that hid this: py_sources_for was taught to follow imports in
# #772, so the python side has been multi-file-aware ever since, while the bash
# side still read one file. A gate that unions one half and not the other cannot
# see a split in the half it does not union — it can only misreport it as a
# divergence.
#
# Scoped to fragments the entry ACTUALLY SOURCES from its own directory, not to
# every *.sh beside it — a directory sweep is wrong here for precisely the
# reason it was wrong there: check-ai-config/ holds `agnix-normalize.sh`, a
# separate executable tool that is NOT part of the patterns pair, and folding
# its slugs in would invent a divergence on a pair that is fine.
#
# Both spellings of the source builtin (`.` and `source`) are matched, and the
# path is matched through the `$_here`-style prefix these scanners use to
# resolve a sibling from the script's own directory rather than $PWD.
sh_sources_for() {
    local sh="$1" dir frag
    dir="${sh%/*}"
    [ -f "$sh" ] || return 0

    printf '%s\n' "$sh"
    command grep -oE '^[[:space:]]*(\.|source)[[:space:]]+"\$[A-Za-z_][A-Za-z0-9_]*/[A-Za-z0-9_.-]+\.sh"' "$sh" 2>/dev/null |
        command sed -e 's|.*/||' -e 's|"$||' |
        command sort -u |
        while IFS= read -r frag; do
            [ -n "$frag" ] || continue
            [ -f "$dir/$frag" ] && printf '%s\n' "$dir/$frag"
        done
}

CUR_SH=""
test_pair_parity() {
    local sh="$CUR_SH"
    local py="${sh%patterns.sh}patterns.py"

    if [ ! -f "$py" ]; then
        skip_test "no sibling patterns.py — parity applies only where both impls exist"
        return 0
    fi

    # BOTH sides are the union over every file of the impl, not the entry alone
    # — python since #772, bash since #991. Each is concatenated into one temp
    # file so category_slugs_of, which takes a single path, needs no change.
    local py_all sh_all
    py_all="$(command mktemp)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    sh_all="$(command mktemp)" || {
        command rm -f "$py_all"
        skip_test "mktemp unavailable"
        return 0
    }
    local src
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        command cat "$src" >>"$py_all"
    done <<<"$(py_sources_for "$sh")"
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        command cat "$src" >>"$sh_all"
    done <<<"$(sh_sources_for "$sh")"

    local diff
    diff="$(category_parity_diff "$sh_all" "$py_all")"
    command rm -f "$py_all" "$sh_all"

    if [ -n "$diff" ]; then
        _fail "category slug sets differ between patterns.sh and patterns.py" \
            "$(printf '%s' "$diff" | command sed 's/^/  /')"
        return 0
    fi
    assert_output_empty "$diff" "category slug sets match"
}

sh_list="$(command find "$PLUGINS_DIR" -type f -name 'patterns.sh' 2>/dev/null | command sort)"

test_corpus_non_empty() {
    assert_not_empty "$sh_list" "At least one patterns.sh must be present (gate is not a no-op)"
}
run_test test_corpus_non_empty "Pre-scan corpus is non-empty"

while IFS= read -r sh; do
    [ -n "$sh" ] || continue
    CUR_SH="$sh"
    rel="${sh#"$PLUGINS_DIR"/}"
    run_test test_pair_parity "$rel: patterns.sh ↔ patterns.py category-slug set"
done <<<"$sh_list"

# --- Self-test: the detector actually fires ---------------------------------
# Committed fixtures under tests/fixtures/category-parity/ prove both arms:
# a one-sided pair MUST be reported; a matching pair MUST pass. Without these a
# no-op detector would pass the real corpus silently.

FIXROOT="$SCRIPT_DIR/fixtures/category-parity"

test_selftest_mismatch_fires() {
    local diff
    diff="$(category_parity_diff \
        "$FIXROOT/mismatch/patterns.sh" "$FIXROOT/mismatch/patterns.py")"
    assert_contains "$diff" "only in patterns.sh: cat-sh-only" \
        "detector must report the sh-only slug in the mismatch fixture"
    assert_contains "$diff" "only in patterns.py: cat-py-only" \
        "detector must report the py-only slug in the mismatch fixture"
}
run_test test_selftest_mismatch_fires "self-test: one-sided fixture is reported"

test_selftest_match_passes() {
    local diff
    diff="$(category_parity_diff \
        "$FIXROOT/match/patterns.sh" "$FIXROOT/match/patterns.py")"
    assert_output_empty "$diff" \
        "detector must report nothing for the matching fixture"
}
run_test test_selftest_match_passes "self-test: matching fixture passes clean"

# --- Self-test: py_sources_for's import scoping (#772) ----------------------
#
# The multi-file union has TWO ways to be wrong, and the real corpus exercises
# neither as a negative:
#
#   too NARROW — read only the entry, and a slug emitted from an imported
#     sibling reads as bash-only (the check-decomposition failure this diff
#     fixes);
#   too WIDE — sweep the directory, and a non-pair sibling's slugs read as
#     python-only (the check-ai-config/agnix-normalize.py failure the first
#     attempt at the fix caused).
#
# Both directions pass over plugins/ today, so nothing there pins the boundary:
# a future edit to the `^from <name> import` pattern could silently widen or
# narrow the union and the suite would stay green. The fixture makes both
# directions reachable — `helper_mod.py` and `second_mod.py` MUST be included,
# `unrelated_tool.py` MUST NOT be.
#
# TWO imported siblings, not one. The real shape has two
# (check-decomposition/patterns.py imports `loc_engine` AND `prose_spec`), and a
# single-sibling fixture cannot distinguish "unions every declared import" from
# "unions the first declared import" — worse, the exact-count assertion below
# would have PINNED the one-sibling answer, locking the bug in.
test_selftest_import_scoping() {
    local srcs
    srcs="$(py_sources_for "$FIXROOT/multifile/patterns.sh")"

    assert_contains "$srcs" "multifile/patterns.py" \
        "py_sources_for includes the entry module"
    assert_contains "$srcs" "multifile/helper_mod.py" \
        "py_sources_for includes the FIRST module the entry imports (union is not entry-only)"
    assert_contains "$srcs" "multifile/second_mod.py" \
        "py_sources_for includes the SECOND module the entry imports (union is not first-import-only)"
    assert_not_contains "$srcs" "unrelated_tool.py" \
        "py_sources_for EXCLUDES a same-dir module the entry does not import (union is not a directory sweep)"

    # Exactly three files — a count check catches a union that is right about
    # these names but wrong about something else in the directory.
    local count
    count="$(command printf '%s\n' "$srcs" | command grep -c '\.py$' || true)"
    assert_equals "3" "$count" "py_sources_for returns exactly the entry + BOTH imported siblings"
}
run_test test_selftest_import_scoping "self-test: py_sources_for unions imports, not the directory (#772)"

# ...and the WHOLE parity path over that fixture is green, which is the property
# test_pair_parity actually asserts. Without this the scoping test above could
# pass while the union never reached category_parity_diff.
test_selftest_multifile_parity_holds() {
    local py_all src diff
    py_all="$(command mktemp)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        command cat "$src" >>"$py_all"
    done <<<"$(py_sources_for "$FIXROOT/multifile/patterns.sh")"

    diff="$(category_parity_diff "$FIXROOT/multifile/patterns.sh" "$py_all")"
    command rm -f "$py_all"

    assert_output_empty "$diff" \
        "a multi-file python impl is in parity with its bash half (slugs from the sibling count)"
}
run_test test_selftest_multifile_parity_holds "self-test: multi-file impl reaches parity through the union (#772)"

# --- Self-test: sh_sources_for's source scoping (#991) -----------------------
#
# The mirror of the two tests above, for the bash side, and it is needed for a
# sharper reason than symmetry: the real corpus has exactly ONE split bash impl
# (check-okf-conformance, split by #991), so if that split were ever undone the
# union would go untested over plugins/ entirely while the suite stayed green.
# The fixture keeps both failure directions reachable no matter what the real
# tree looks like — too NARROW (entry-only, the #991 failure itself) and too
# WIDE (a directory sweep folding in `unrelated-tool.sh`).
#
# One sourced fragment, not two, unlike the python fixture: the `^from <name>
# import` pattern there can plausibly stop after the first match, while a
# `grep -oE` over source lines has no such first-match failure mode. The
# exact-count assertion still pins the boundary.
test_selftest_source_scoping() {
    local srcs
    srcs="$(sh_sources_for "$FIXROOT/multifile-sh/patterns.sh")"

    assert_contains "$srcs" "multifile-sh/patterns.sh" \
        "sh_sources_for includes the entry script"
    assert_contains "$srcs" "multifile-sh/bundle-frag.sh" \
        "sh_sources_for includes the sourced fragment (union is not entry-only)"
    assert_not_contains "$srcs" "unrelated-tool.sh" \
        "sh_sources_for EXCLUDES a same-dir script the entry does not source (union is not a directory sweep)"

    local count
    count="$(command printf '%s\n' "$srcs" | command grep -c '\.sh$' || true)"
    assert_equals "2" "$count" "sh_sources_for returns exactly the entry + its sourced fragment"
}
run_test test_selftest_source_scoping "self-test: sh_sources_for unions sourced fragments, not the directory (#991)"

# ...and the whole parity path over that fixture is green. Same reason as the
# python twin above: the scoping test could pass while the union never reached
# category_parity_diff.
test_selftest_multifile_sh_parity_holds() {
    local sh_all src diff
    sh_all="$(command mktemp)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        command cat "$src" >>"$sh_all"
    done <<<"$(sh_sources_for "$FIXROOT/multifile-sh/patterns.sh")"

    diff="$(category_parity_diff "$sh_all" "$FIXROOT/multifile-sh/patterns.py")"
    command rm -f "$sh_all"

    assert_output_empty "$diff" \
        "a multi-file bash impl is in parity with its python half (slugs from the fragment count)"
}
run_test test_selftest_multifile_sh_parity_holds "self-test: split-bash impl reaches parity through the union (#991)"

generate_report
