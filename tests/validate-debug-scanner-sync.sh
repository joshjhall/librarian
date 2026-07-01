#!/usr/bin/env bash
# Debug-statement scanner drift gate (issue #89).
#
# The per-language debug-statement detection `case` is DELIBERATELY duplicated
# across two pre-scan scripts that live in SEPARATE, independently-installed
# plugins:
#
#   plugins/review-audit/skills/check-code-health/patterns.sh
#   plugins/workflow/skills/ship-issue/pre-review-gates.sh
#
# They cannot share a sourced library: CLAUDE_PLUGIN_ROOT is plugin-scoped, the
# plugins declare no dependency on each other, and a user may install `workflow`
# without `review-audit`. So the scan logic must physically exist in both. The
# two copies had already drifted (evidence strings diverged) before this gate.
#
# Each copy brackets the shared region with sentinel comments:
#
#   # >>> shared:debug-statement-scan ...
#   case "$file" in ... esac
#   # <<< shared:debug-statement-scan
#
# This gate extracts both regions, normalizes each to its set of unique,
# non-blank, trimmed lines, and asserts the sets are identical. Trimming leading
# whitespace is deliberate: patterns.sh nests the block one indent level deeper
# (inside an `if`) than pre-review-gates.sh (inside a function), so the arms are
# byte-identical only after indentation is stripped — the regexes and evidence
# strings are the invariant that must hold.
#
# A synthetic tamper check proves the detector fires (mirrors the
# negative-fixture discipline of tests/validate-template-sync.sh, the exemplar
# for this whole gate).
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

test_suite "debug-statement scanner sync (#89)"

# Extract the lines strictly between the sentinel comments. The opening sentinel
# and closing sentinel lines themselves are excluded (the sentinel text differs
# between the two files — each names the other — so pinning them would be wrong).
extract_shared() {
    /usr/bin/awk '
        /# >>> shared:debug-statement-scan/ { in_region = 1; next }
        /# <<< shared:debug-statement-scan/ { in_region = 0 }
        in_region { print }
    ' "$1"
}

# Normalize to the sorted set of unique, non-blank, trimmed lines. Trimming
# collapses the indentation difference between the two nesting depths; sort -u
# makes the comparison order-insensitive while still catching any regex or
# evidence-string divergence.
normalize() {
    /usr/bin/awk '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        $0 != "" { print }
    ' | LC_ALL=C /usr/bin/sort -u
}

# The two shared regions agree on their set of unique lines. This is the live
# drift guard.
test_shared_regions_match() {
    assert_file_exists "$CANONICAL" "check-code-health/patterns.sh exists"
    assert_file_exists "$DUPLICATE" "ship-issue/pre-review-gates.sh exists"

    local canonical duplicate
    canonical="$(extract_shared "$CANONICAL" | normalize)"
    duplicate="$(extract_shared "$DUPLICATE" | normalize)"

    assert_not_empty "$canonical" "canonical shared region is non-empty (sentinels intact in patterns.sh)"
    assert_not_empty "$duplicate" "duplicate shared region is non-empty (sentinels intact in pre-review-gates.sh)"

    if [ "$canonical" != "$duplicate" ]; then
        local diff_out
        diff_out="$(/usr/bin/diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$duplicate") || true)"
        local detail=()
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$diff_out"
        _fail "debug-statement scan drifted between patterns.sh and pre-review-gates.sh" \
            "Lines prefixed '<' are patterns.sh-only; '>' are pre-review-gates.sh-only. Re-sync the two copies." \
            "${detail[@]}"
    fi
}

# The detector FIRES: a tampered copy (one evidence string changed) must break
# set equality. Without this, a normalize() that collapsed everything to empty
# would let the live check pass vacuously.
test_detector_fires_on_drift() {
    local canonical duplicate tampered
    canonical="$(extract_shared "$CANONICAL" | normalize)"
    duplicate="$(extract_shared "$DUPLICATE" | normalize)"
    # Simulate a duplicate that renamed one evidence string.
    tampered="$(extract_shared "$DUPLICATE" |
        /usr/bin/sed 's/Console debug statement/Console log statement/' | normalize)"

    # Two guards so this negative fixture can't pass for the wrong reason:
    #   1. `tampered` must be non-empty — else a broken extract_shared (returns
    #      nothing) trivially satisfies the inequality below while proving nothing.
    #   2. the sed must have actually changed the duplicate — else a pre-existing
    #      drift (the "Console debug statement" evidence already gone) makes sed a
    #      no-op, and `canonical != tampered` would hold off the prior drift, not
    #      the synthetic tamper. Comparing `duplicate` vs `tampered` proves the
    #      edit bit.
    # Compare in plain bash (NOT via assert_true, which eval's its argument —
    # the shared region contains shell metacharacters like $(...) and quotes
    # that eval would execute). assert_equals compares its parameters directly.
    local edit_bit="no" drift="none"
    [ "$duplicate" != "$tampered" ] && edit_bit="yes"
    [ "$canonical" != "$tampered" ] && drift="detected"

    assert_not_empty "$tampered" "tampered extract is non-empty (extract_shared still works)"
    assert_equals "yes" "$edit_bit" \
        "the synthetic tamper actually changed the shared region (Console debug statement present)"
    assert_equals "detected" "$drift" \
        "a one-line edit to the shared region is detected as drift"
}

run_test test_shared_regions_match "Shared debug-statement region matches between the two plugins"
run_test test_detector_fires_on_drift "Drift detector fires on a tampered shared region"

generate_report
