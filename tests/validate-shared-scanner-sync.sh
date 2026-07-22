#!/usr/bin/env bash
# Shared-scanner drift gate (issues #89, #132, #133).
#
# Two pre-scan scripts live in SEPARATE, independently-installed plugins and
# share more than one region of logic by DELIBERATE duplication:
#
#   plugins/review-audit/skills/check-code-health/patterns.sh
#   plugins/workflow/skills/ship-issue/pre-review-gates.sh
#
# They cannot share a sourced library: CLAUDE_PLUGIN_ROOT is plugin-scoped, the
# plugins declare no dependency on each other, and a user may install `workflow`
# without `review-audit`. So the shared logic must physically exist in both.
#
# Each shared region is bracketed by matching sentinel comments, e.g.:
#
#   # >>> shared:<region> ...
#   <shared code>
#   # <<< shared:<region>
#
# This gate is PARAMETERIZED over the list of shared regions (SHARED_REGIONS
# below). For each region it extracts both copies, normalizes each to its
# ordered sequence of non-blank, trimmed lines, and asserts the sequences are
# identical. Trimming leading whitespace is deliberate: the two files nest the
# regions at different indent depths (patterns.sh inside a `while`/`if`,
# pre-review-gates.sh at top level or inside a function), so the bodies are
# byte-identical only after indentation is stripped — the regexes, evidence
# strings, AND their order are the invariant. The comparison is an ordered
# multiset (NOT `sort -u`): deduplicating or sorting would let a duplicated or
# reordered line slip through undetected.
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

CANONICAL="$REPO_ROOT/plugins/review-audit/skills/check-code-health/patterns.sh"
DUPLICATE="$REPO_ROOT/plugins/workflow/skills/ship-issue/pre-review-gates.sh"

# The shared regions pinned by this gate. Add a region name here when a new
# `# >>> shared:<name>` block is introduced in both scripts.
SHARED_REGIONS=(debug-statement-scan is-test-file)

test_suite "shared scanner sync (#89/#132/#133)"

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

# assert_region_synced REGION — both copies of REGION are present (one open +
# one close sentinel each) and byte-identical after normalization.
assert_region_synced() {
    local region="$1"
    local open="# >>> shared:${region}" close="# <<< shared:${region}"

    assert_equals "1" "$(sentinel_count "$open" "$CANONICAL")" "patterns.sh: one opening sentinel for ${region}"
    assert_equals "1" "$(sentinel_count "$close" "$CANONICAL")" "patterns.sh: one closing sentinel for ${region}"
    assert_equals "1" "$(sentinel_count "$open" "$DUPLICATE")" "pre-review-gates.sh: one opening sentinel for ${region}"
    assert_equals "1" "$(sentinel_count "$close" "$DUPLICATE")" "pre-review-gates.sh: one closing sentinel for ${region}"

    local canonical duplicate
    canonical="$(extract_shared "$CANONICAL" "$region" | normalize)"
    duplicate="$(extract_shared "$DUPLICATE" "$region" | normalize)"

    assert_not_empty "$canonical" "patterns.sh ${region} region is non-empty (sentinels intact)"
    assert_not_empty "$duplicate" "pre-review-gates.sh ${region} region is non-empty (sentinels intact)"

    if [ "$canonical" != "$duplicate" ]; then
        local diff_out
        diff_out="$(command diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$duplicate") || true)"
        local detail=()
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$diff_out"
        _fail "shared:${region} drifted between patterns.sh and pre-review-gates.sh" \
            "Lines prefixed '<' are patterns.sh-only; '>' are pre-review-gates.sh-only. Re-sync the two copies." \
            "${detail[@]}"
    fi
}

# Every shared region is in sync between the two plugin copies. This is the live
# drift guard.
test_all_regions_match() {
    assert_file_exists "$CANONICAL" "check-code-health/patterns.sh exists"
    assert_file_exists "$DUPLICATE" "ship-issue/pre-review-gates.sh exists"

    local region
    for region in "${SHARED_REGIONS[@]}"; do
        assert_region_synced "$region"
    done
}

# The debug region must carry an arm for every language it claims to cover.
# Guards against a copy silently losing a language arm (which the multiset
# equality would still catch as drift, but this pins the shape independently and
# makes the tamper fixture below meaningful for non-JS arms — see #133).
test_debug_region_has_all_language_arms() {
    local body arm
    body="$(extract_shared "$CANONICAL" debug-statement-scan)"
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
    dbg="$(extract_shared "$CANONICAL" debug-statement-scan | normalize)"
    dbg_tampered="$(extract_shared "$CANONICAL" debug-statement-scan |
        command sed 's/Debug print statement/Debug print/' | normalize)"
    assert_not_empty "$dbg_tampered" "tampered debug extract is non-empty (extract still works)"
    local dbg_changed="no" dbg_drift="none"
    [ "$dbg" != "$dbg_tampered" ] && dbg_changed="yes"
    [ "$dbg" != "$dbg_tampered" ] && dbg_drift="detected"
    assert_equals "yes" "$dbg_changed" "the debug tamper actually changed the region (non-JS 'Debug print statement' present)"
    assert_equals "detected" "$dbg_drift" "a one-line edit to the debug region is detected as drift"

    # Region 2: is-test-file — tamper one glob arm.
    local itf itf_tampered
    itf="$(extract_shared "$CANONICAL" is-test-file | normalize)"
    itf_tampered="$(extract_shared "$CANONICAL" is-test-file |
        command sed 's/_spec\./_zzz./' | normalize)"
    assert_not_empty "$itf_tampered" "tampered is-test-file extract is non-empty"
    local itf_changed="no" itf_drift="none"
    [ "$itf" != "$itf_tampered" ] && itf_changed="yes"
    [ "$itf" != "$itf_tampered" ] && itf_drift="detected"
    assert_equals "yes" "$itf_changed" "the is-test-file tamper actually changed the region (_spec. arm present)"
    assert_equals "detected" "$itf_drift" "a one-line edit to the is-test-file region is detected as drift"
}

run_test test_all_regions_match "All shared regions match between the two plugins"
run_test test_debug_region_has_all_language_arms "Debug region covers every advertised language arm"
run_test test_detector_fires_on_drift "Drift detector fires on a tampered region (debug + is-test-file)"

generate_report
