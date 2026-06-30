#!/usr/bin/env bash
# Issue-template drift gate for codebase-audit (issue #90 / #78 item 3).
#
# The codebase-audit `workflow.js` harness hands each issue-writer a literal
# `ISSUE_TEMPLATE` string. That agent has no Read tool (file I/O is denied in its
# definition) and no install-independent path to the skill dir, so it CANNOT
# source the template itself — the harness must inline it. That makes the inline
# `ISSUE_TEMPLATE` a DELIBERATE DUPLICATE of `issue-templates.md` § Issue Template
# (the canonical copy). A duplicate with no guard silently drifts: an edit to one
# copy leaves the rendered issue body diverging from the documented template with
# nothing to catch it.
#
# This gate pins the two together. It extracts both templates, normalizes each to
# its set of unique non-blank trimmed lines, and asserts the sets are identical.
# (The canonical copy shows the `- [ ]` findings line twice to illustrate
# repetition while the inline copy lists it once, so byte-equality is wrong —
# unique-line set equality is the invariant that actually holds.)
#
# Pure bash + coreutils; no node/jq. A synthetic tamper check proves the detector
# fires (mirrors the negative-fixture discipline of the other validate-*.sh
# gates).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

SKILL_DIR="$REPO_ROOT/plugins/review-audit/skills/codebase-audit"
HARNESS="$SKILL_DIR/workflow.js"
TEMPLATES_MD="$SKILL_DIR/issue-templates.md"

test_suite "codebase-audit issue-template sync"

# Normalize a template to its sorted set of unique, non-blank, trimmed lines.
# Reads from stdin, writes the normalized set to stdout.
normalize_template() {
    /usr/bin/awk '
        { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
        $0 != "" { print }
    ' | LC_ALL=C /usr/bin/sort -u
}

# Extract the canonical template: the fenced ```markdown block under the
# `## Issue Template` heading in issue-templates.md.
extract_canonical() {
    /usr/bin/awk '
        /^## Issue Template[[:space:]]*$/ { in_section = 1; next }
        in_section && /^```/ {
            if (in_fence) { exit }
            in_fence = 1; next
        }
        in_fence { print }
    ' "$TEMPLATES_MD"
}

# Extract the inline template: the single-quoted elements of the
# `const ISSUE_TEMPLATE = [ ... ].join('\n')` array in workflow.js. Strips the
# leading indent + opening quote and the trailing quote/comma so an element like
# `  '### Findings',` yields `### Findings` and an empty `''` yields a blank line.
extract_inline() {
    /usr/bin/awk '
        /const ISSUE_TEMPLATE = \[/ { in_arr = 1; next }
        in_arr && /^\]\.join\(/ { exit }
        in_arr {
            sub(/^[[:space:]]*/, "")
            sub(/,[[:space:]]*$/, "")
            sub(/^'\''/, "")
            sub(/'\''$/, "")
            print
        }
    ' "$HARNESS"
}

# The inline ISSUE_TEMPLATE and the canonical issue-templates.md block agree on
# their set of unique lines. This is the live drift guard.
test_inline_matches_canonical() {
    assert_file_exists "$HARNESS" "harness workflow.js exists"
    assert_file_exists "$TEMPLATES_MD" "issue-templates.md exists"

    local canonical inline
    canonical="$(extract_canonical | normalize_template)"
    inline="$(extract_inline | normalize_template)"

    assert_not_empty "$canonical" "canonical template block is non-empty (heading/fence intact)"
    assert_not_empty "$inline" "inline ISSUE_TEMPLATE array is non-empty (markers intact)"

    if [ "$canonical" != "$inline" ]; then
        local diff_out
        diff_out="$(/usr/bin/diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$inline") || true)"
        local detail=()
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$diff_out"
        _fail "Inline ISSUE_TEMPLATE drifted from issue-templates.md § Issue Template" \
            "Lines prefixed '<' are canonical-only; '>' are inline-only. Re-sync the two copies." \
            "${detail[@]}"
    fi
}

# The detector FIRES: a tampered inline copy (one line changed) must break set
# equality. Without this, a normalizer that collapsed everything to empty would
# let the live check pass vacuously.
test_detector_fires_on_drift() {
    local canonical inline tampered
    canonical="$(extract_canonical | normalize_template)"
    inline="$(extract_inline | normalize_template)"
    # Simulate an inline copy that renamed a section heading.
    tampered="$(extract_inline | /usr/bin/sed 's/### Findings/### Finding Items/' | normalize_template)"

    # Two guards so this negative fixture can't pass for the wrong reason:
    #   1. `tampered` must be non-empty — else a broken extract_inline (returns
    #      nothing) trivially satisfies the inequality below while proving nothing.
    #   2. the sed must have actually changed the inline copy — else a pre-existing
    #      drift (the live `### Findings` heading already gone) makes sed a no-op,
    #      and `canonical != tampered` would hold off the prior drift, not the
    #      synthetic tamper. Comparing `inline` vs `tampered` proves the edit bit.
    assert_not_empty "$tampered" "tampered inline extract is non-empty (extract_inline still works)"
    assert_true "[ \"$inline\" != \"$tampered\" ]" \
        "the synthetic tamper actually changed the inline template (### Findings heading present)"
    assert_true "[ \"$canonical\" != \"$tampered\" ]" \
        "A one-line edit to the inline template is detected as drift"
}

run_test test_inline_matches_canonical "Inline ISSUE_TEMPLATE matches issue-templates.md § Issue Template"
run_test test_detector_fires_on_drift "Drift detector fires on a tampered inline template"

generate_report
