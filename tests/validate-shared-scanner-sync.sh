#!/usr/bin/env bash
# Shared-scanner drift gate (issues #89, #132, #133, #609).
#
# Pre-scan scripts living in SEPARATE, independently-installed plugins share
# regions of logic by DELIBERATE duplication. Two such PAIRS are pinned here:
#
#   check-code-health/patterns.sh   <-> ship-issue/pre-review-gates.sh
#   loop-make-it-tested/patterns.sh <-> ship-issue/pre-review-gates.sh   (#609)
#
# They cannot share a sourced library: CLAUDE_PLUGIN_ROOT is plugin-scoped, the
# plugins declare no dependency on each other, and a user may install `workflow`
# without `review-audit` or `dev-core`. So the shared logic must physically exist
# in both halves of each pair.
#
# Each shared region is bracketed by matching sentinel comments, e.g.:
#
#   # >>> shared:<region> ...
#   <shared code>
#   # <<< shared:<region>
#
# This gate is PARAMETERIZED over a list of (canonical, duplicate, regions)
# triples (SHARED_PAIRS below). For each region of each pair it extracts both
# copies, normalizes each to its ordered sequence of non-blank, trimmed lines,
# and asserts the sequences are identical. Trimming leading whitespace is
# deliberate: the copies nest the regions at different indent depths (inside a
# `while`/`if` in one file, at top level or inside a function in the other), so
# the bodies are byte-identical only after indentation is stripped — the
# regexes, evidence strings, AND their order are the invariant. The comparison
# is an ordered multiset (NOT `sort -u`): deduplicating or sorting would let a
# duplicated or reordered line slip through undetected.
#
# A region's sentinels bracket CODE, not the doc comment above it: a copy's
# leading prose legitimately differs per plugin (the py-public-symbols pair is
# the live example). Comments INSIDE a region are compared like any other line.
#
# Synthetic tamper checks prove the detector fires (mirrors the negative-fixture
# discipline of tests/validate-template-sync.sh, the exemplar for this gate).
#
# Pure bash + coreutils; no node/jq. Full /usr/bin/* paths per project shell
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# The file pairs pinned by this gate, one per line:
#
#   <canonical>|<duplicate>|<space-separated region names>
#
# Paths are repo-relative (joined to $REPO_ROOT at use) so the entries stay
# readable and failure messages can print the short form. Pipe-delimited fields
# in an indexed array rather than an associative one: bash 3.2 (stock macOS) has
# no `declare -A`, and a pair needs three fields anyway.
#
# Add a region name to a pair's third field when a new `# >>> shared:<name>`
# block is introduced in both of that pair's files; add a whole line when a new
# duplicated-logic pair appears.
SHARED_PAIRS=(
    "plugins/review-audit/skills/check-code-health/patterns.sh|plugins/workflow/skills/ship-issue/pre-review-gates.sh|debug-statement-scan is-test-file scanner-pattern-line"
    "plugins/dev-core/skills/loop-make-it-tested/patterns.sh|plugins/workflow/skills/ship-issue/pre-review-gates.sh|py-public-symbols"
)

# Pair-specific paths used by the targeted tests below (the language-arm shape
# check and the two tamper fixtures). Kept as consts so a path edit above is a
# one-line change here too.
HEALTH_PATTERNS="$REPO_ROOT/plugins/review-audit/skills/check-code-health/patterns.sh"
TESTED_PATTERNS="$REPO_ROOT/plugins/dev-core/skills/loop-make-it-tested/patterns.sh"
PRE_REVIEW_GATES="$REPO_ROOT/plugins/workflow/skills/ship-issue/pre-review-gates.sh"

test_suite "shared scanner sync (#89/#132/#133/#609)"

# extract_shared FILE REGION — the lines strictly between the sentinel comments
# for REGION. The sentinel lines themselves are excluded: their text names the
# *other* file, so it differs between copies and must not be compared.
extract_shared() {
    command awk -v region="$2" '
        index($0, "# >>> shared:" region) { in_region = 1; next }
        index($0, "# <<< shared:" region) { in_region = 0 }
        in_region { print }
    ' "$1"
}

# Normalize to the ordered sequence of non-blank, trimmed lines. Trimming
# collapses the indentation difference between the two nesting depths. Order and
# duplicates are preserved (no sort, no -u), so the comparison is a true
# ordered-multiset equality: a reordered, duplicated, or dropped line all
# surface as drift, not just a changed evidence string.
normalize() {
    command awk '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        $0 != "" { print }
    '
}

# sentinel_count NEEDLE FILE — occurrences of the fixed string NEEDLE in FILE.
sentinel_count() {
    command grep -cF "$1" "$2" || true
}

# label_for PATH — the plugin-qualified short name used in assertion messages.
# Both pairs' canonical file is *named* `patterns.sh`, so a bare basename would
# make the second pair's failures read as the first pair's. Keep the last two
# path segments (`<skill>/patterns.sh`), which are unique across the pairs.
label_for() {
    local path="$1" tail
    tail="${path%/*}"
    printf '%s/%s' "${tail##*/}" "${path##*/}"
}

# assert_region_synced CANONICAL_FILE DUPLICATE_FILE REGION — both copies of
# REGION are present (one open + one close sentinel each) and byte-identical
# after normalization. Files are passed explicitly rather than read from globals
# so the same assertion serves every pair in SHARED_PAIRS.
assert_region_synced() {
    local canonical_file="$1" duplicate_file="$2" region="$3"
    local open="# >>> shared:${region}" close="# <<< shared:${region}"
    local can_label dup_label
    can_label="$(label_for "$canonical_file")"
    dup_label="$(label_for "$duplicate_file")"

    assert_equals "1" "$(sentinel_count "$open" "$canonical_file")" "${can_label}: one opening sentinel for ${region}"
    assert_equals "1" "$(sentinel_count "$close" "$canonical_file")" "${can_label}: one closing sentinel for ${region}"
    assert_equals "1" "$(sentinel_count "$open" "$duplicate_file")" "${dup_label}: one opening sentinel for ${region}"
    assert_equals "1" "$(sentinel_count "$close" "$duplicate_file")" "${dup_label}: one closing sentinel for ${region}"

    local canonical duplicate
    canonical="$(extract_shared "$canonical_file" "$region" | normalize)"
    duplicate="$(extract_shared "$duplicate_file" "$region" | normalize)"

    assert_not_empty "$canonical" "${can_label} ${region} region is non-empty (sentinels intact)"
    assert_not_empty "$duplicate" "${dup_label} ${region} region is non-empty (sentinels intact)"

    if [ "$canonical" != "$duplicate" ]; then
        local diff_out
        diff_out="$(command diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$duplicate") || true)"
        local detail=()
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$diff_out"
        _fail "shared:${region} drifted between ${can_label} and ${dup_label}" \
            "Lines prefixed '<' are ${can_label}-only; '>' are ${dup_label}-only. Re-sync the two copies." \
            "${detail[@]}"
    fi
}

# Every shared region of every pinned pair is in sync. This is the live drift
# guard.
test_all_regions_match() {
    local entry canonical_rel duplicate_rel regions region

    for entry in "${SHARED_PAIRS[@]}"; do
        # Field-split on the delimiter. Region names are space-separated inside
        # the third field and are re-split by the unquoted `for` below.
        IFS='|' read -r canonical_rel duplicate_rel regions <<<"$entry"

        assert_not_empty "$canonical_rel" "pair entry declares a canonical file"
        assert_not_empty "$duplicate_rel" "pair entry declares a duplicate file"
        assert_not_empty "$regions" "pair ${canonical_rel} declares at least one region"

        assert_file_exists "$REPO_ROOT/$canonical_rel" "${canonical_rel} exists"
        assert_file_exists "$REPO_ROOT/$duplicate_rel" "${duplicate_rel} exists"

        # shellcheck disable=SC2086  # deliberate word-split: regions is a list
        for region in $regions; do
            assert_region_synced "$REPO_ROOT/$canonical_rel" "$REPO_ROOT/$duplicate_rel" "$region"
        done
    done
}

# The debug region must carry an arm for every language it claims to cover.
# Guards against a copy silently losing a language arm (which the multiset
# equality would still catch as drift, but this pins the shape independently and
# makes the tamper fixture below meaningful for non-JS arms — see #133).
test_debug_region_has_all_language_arms() {
    local body arm
    body="$(extract_shared "$HEALTH_PATTERNS" debug-statement-scan)"
    for arm in '*.py)' '*.js' '*.rb)' '*.go)' '*.java'; do
        assert_contains "$body" "$arm" "debug region covers the ${arm} arm"
    done
}

# The detector FIRES on drift in EACH region. A tamper on a non-JS line proves
# the extract/normalize path works beyond the first arm (#133). Comparison is in
# plain bash — NOT assert_true, which eval's its argument, and the regions hold
# shell metacharacters ($(...), quotes, |) that eval would execute.
test_detector_fires_on_drift() {
    # Region 1: debug-statement-scan — tamper a Python (non-JS) evidence string.
    local dbg dbg_tampered
    dbg="$(extract_shared "$HEALTH_PATTERNS" debug-statement-scan | normalize)"
    dbg_tampered="$(extract_shared "$HEALTH_PATTERNS" debug-statement-scan |
        command sed 's/Debug print statement/Debug print/' | normalize)"
    assert_not_empty "$dbg_tampered" "tampered debug extract is non-empty (extract still works)"
    local dbg_changed="no" dbg_drift="none"
    [ "$dbg" != "$dbg_tampered" ] && dbg_changed="yes"
    [ "$dbg" != "$dbg_tampered" ] && dbg_drift="detected"
    assert_equals "yes" "$dbg_changed" "the debug tamper actually changed the region (non-JS 'Debug print statement' present)"
    assert_equals "detected" "$dbg_drift" "a one-line edit to the debug region is detected as drift"

    # Region 2: is-test-file — tamper one glob arm.
    local itf itf_tampered
    itf="$(extract_shared "$HEALTH_PATTERNS" is-test-file | normalize)"
    itf_tampered="$(extract_shared "$HEALTH_PATTERNS" is-test-file |
        command sed 's/_spec\./_zzz./' | normalize)"
    assert_not_empty "$itf_tampered" "tampered is-test-file extract is non-empty"
    local itf_changed="no" itf_drift="none"
    [ "$itf" != "$itf_tampered" ] && itf_changed="yes"
    [ "$itf" != "$itf_tampered" ] && itf_drift="detected"
    assert_equals "yes" "$itf_changed" "the is-test-file tamper actually changed the region (_spec. arm present)"
    assert_equals "detected" "$itf_drift" "a one-line edit to the is-test-file region is detected as drift"
}

# label_for actually DISAMBIGUATES the two pairs. Both pairs' canonical file is
# named `patterns.sh`, so this helper is the only thing keeping pair 2's failure
# messages from reading as pair 1's — and it renders exclusively on the failure
# path, which a green suite never exercises. Without this test, an edit to the
# tail-stripping expression that collapsed both labels back to `patterns.sh`
# would ship green.
test_label_for_disambiguates_the_pairs() {
    assert_equals "check-code-health/patterns.sh" "$(label_for "$HEALTH_PATTERNS")" \
        "label_for keeps the check-code-health copy distinguishable"
    assert_equals "loop-make-it-tested/patterns.sh" "$(label_for "$TESTED_PATTERNS")" \
        "label_for keeps the loop-make-it-tested copy distinguishable"
    assert_equals "ship-issue/pre-review-gates.sh" "$(label_for "$PRE_REVIEW_GATES")" \
        "label_for labels the shared duplicate by its skill dir"

    # The property that matters is DISTINCTNESS, not the strings alone: a bare
    # basename would satisfy neither assertion above nor this one.
    local a b
    a="$(label_for "$HEALTH_PATTERNS")"
    b="$(label_for "$TESTED_PATTERNS")"
    local distinct="no"
    [ "$a" != "$b" ] && distinct="yes"
    assert_equals "yes" "$distinct" "the two same-named patterns.sh copies get different labels"
}

# The detector FIRES on drift in the SECOND pair's region (#609). Deliberately
# shaped as a genuine CROSS-FILE comparison, unlike the single-file tampers
# above: the tampered text is extracted from the DUPLICATE
# (ship-issue/pre-review-gates.sh) and compared against the UNTAMPERED CANONICAL
# (loop-make-it-tested/patterns.sh). A fixture that tampered one file against
# itself would pass even if the two files were never actually paired — the
# pairing is the thing under test.
#
# The untampered-match assertion is what keeps this honest: it proves the two
# extracts are equal to begin with, so the inequality below can only come from
# the tamper. Without it, a broken extract returning empty for one side would
# make BOTH branches report "detected" and the fixture would pass vacuously.
#
# Comparison is plain bash, NOT assert_true — the region holds shell
# metacharacters ($(...), quotes, |) that assert_true's eval would execute.
test_detector_fires_on_py_region_drift() {
    local canonical duplicate tampered

    canonical="$(extract_shared "$TESTED_PATTERNS" py-public-symbols | normalize)"
    duplicate="$(extract_shared "$PRE_REVIEW_GATES" py-public-symbols | normalize)"

    assert_not_empty "$canonical" "loop-make-it-tested py-public-symbols extract is non-empty"
    assert_not_empty "$duplicate" "pre-review-gates py-public-symbols extract is non-empty"

    local baseline="differs"
    [ "$canonical" = "$duplicate" ] && baseline="matches"
    assert_equals "matches" "$baseline" "the untampered py-public-symbols pair matches (tamper is the only variable)"

    # Tamper a BEHAVIORAL line — py_symbol_is_public's `none` arm, which decides
    # whether a main()-guarded module exposes any public API at all. Prose would
    # prove less: this is the line a real one-sided bug fix would touch.
    tampered="$(extract_shared "$PRE_REVIEW_GATES" py-public-symbols |
        command sed 's/none) return 1 ;;/none) return 9 ;;/' | normalize)"
    assert_not_empty "$tampered" "tampered py-public-symbols extract is non-empty (extract still works)"

    local tamper_took="no"
    [ "$duplicate" != "$tampered" ] && tamper_took="yes"
    assert_equals "yes" "$tamper_took" "the tamper actually changed the region (the 'none) return 1' arm is present)"

    local drift="none"
    [ "$canonical" != "$tampered" ] && drift="detected"
    assert_equals "detected" "$drift" "a one-line edit to pre-review-gates' copy is detected as drift against patterns.sh"
}

run_test test_all_regions_match "All shared regions match across every pinned pair"
run_test test_label_for_disambiguates_the_pairs "label_for disambiguates the two same-named patterns.sh copies"
run_test test_debug_region_has_all_language_arms "Debug region covers every advertised language arm"
run_test test_detector_fires_on_drift "Drift detector fires on a tampered region (debug + is-test-file)"
run_test test_detector_fires_on_py_region_drift "Drift detector fires across the py-public-symbols pair (#609)"

generate_report
