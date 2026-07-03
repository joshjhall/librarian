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

CUR_SH=""
test_pair_parity() {
    local sh="$CUR_SH"
    local py="${sh%patterns.sh}patterns.py"

    if [ ! -f "$py" ]; then
        skip_test "no sibling patterns.py — parity applies only where both impls exist"
        return 0
    fi

    local diff
    diff="$(category_parity_diff "$sh" "$py")"

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

generate_report
