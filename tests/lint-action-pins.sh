#!/usr/bin/env bash
# Format gate for pinned GitHub Actions (issue #50).
#
# PR #46 pinned every `uses:` in .github/workflows/*.yml to a full 40-char
# commit SHA with a trailing `# vX.Y.Z` version comment. Those comments are
# purely documentary — nothing verified that a `uses:` stayed pinned-and-
# commented. A hand-edit back to a floating tag (`@v4`), a SHA with the comment
# dropped, or a comment that no longer parses would all slip through silently,
# undermining the audit value of pinning. This gate asserts the FORMAT of every
# action ref: `<owner/repo[/path]>@<40-hex SHA> # vX...`.
#
# Scope boundary: it checks the *shape* (pinned SHA + version comment present),
# NOT that the SHA actually resolves to the tag in the comment — that requires a
# network call to the GitHub API and is owned by Dependabot (.github/dependabot.yml),
# which bumps the SHA and the comment together. This gate is the offline
# backstop that catches a manual regression between Dependabot runs.
#
# Exempt: local `./...` action refs and `docker://` refs (neither is a
# tag-pinnable GitHub action). Pure bash + coreutils + grep; no network, no jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

# A `uses:` value is valid when it is `<name>@<40 hex> # v<digit>...`. The name
# allows the owner/repo[/sub/path] of a reusable workflow; the SHA is exactly 40
# lowercase hex (git/Dependabot always emit lowercase); the trailing comment must
# start `# v` + a digit. The `$` anchor closes the ref end-to-end so trailing
# garbage (a second `@`, a malformed suffix) after the version token is rejected
# rather than passing on a substring match — the version token itself may carry a
# dotted suffix (`v4.3.1`) so the tail allows `.`, digits, and `-`/alphanum.
PIN_RE='^[A-Za-z0-9._/-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9][0-9A-Za-z._-]*$'

test_suite "Action pin format (#50)"

# Match real YAML `uses:` keys only: step form (`- uses:`) and job/reusable-
# workflow form (`uses:`), both at the start of the line modulo indentation.
# This avoids matching the literal token `uses:` inside prose or a comment.
_uses_lines() {
    command grep -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]' "$1" 2>/dev/null || true
}

# scan_file <path> — populate CUR_VIOLATIONS with one indented line per
# unpinned/uncommented `uses:` found in the file (empty when all are valid).
CUR_FILE=""
CUR_VIOLATIONS=""
scan_file() {
    local file="$1"
    CUR_VIOLATIONS=""
    local entry lineno line ref
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        lineno="${entry%%:*}"
        line="${entry#*:}"
        # Value after `uses:`; trim leading whitespace and surrounding quotes.
        ref="${line#*uses:}"
        ref="${ref#"${ref%%[![:space:]]*}"}"
        ref="${ref%\"}"
        ref="${ref#\"}"
        ref="${ref%\'}"
        ref="${ref#\'}"
        # Local and docker refs are not tag-pinnable GitHub actions — exempt.
        case "$ref" in
            ./* | docker://*) continue ;;
        esac
        if ! printf '%s' "$ref" | command grep -qE "$PIN_RE"; then
            CUR_VIOLATIONS+="line ${lineno}: ${ref}"$'\n'
        fi
    done < <(_uses_lines "$file")
}

# Per-file test body (reads CUR_FILE; asserts no violations).
test_file_pins() {
    scan_file "$CUR_FILE"
    assert_equals "" "$CUR_VIOLATIONS" \
        "Every uses: in $(command basename "$CUR_FILE") must be <40-hex SHA> # vX.Y.Z"
}

# Negative case: scan_file's violation branch must actually fire. Without this,
# a regression in PIN_RE or the ref-extraction stripping (e.g. widening the hex
# quantifier) would report PASS while silently letting unpinned refs through —
# the gate would be false-green. We plant a throwaway workflow holding one good
# ref plus the four bad forms the gate must reject, run the REAL scan_file
# against it, and assert exactly the bad refs surface. Mirrors the two-branch
# coverage of tests/golem-gate-watch.sh.
test_negative_case_fires() {
    local tmp
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    local good="actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1"
    command cat >"$tmp/bad.yml" <<EOF
jobs:
  x:
    steps:
      - uses: ${good}
      - uses: actions/checkout@v4
      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020
      - uses: some/action@main # not a version comment
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1 @trailing
EOF

    scan_file "$tmp/bad.yml"

    assert_not_empty "$CUR_VIOLATIONS" "scan_file flags non-conforming refs (violation branch fires)"
    # Each bad form must be reported by name; the good ref must NOT be.
    assert_contains "$CUR_VIOLATIONS" "actions/checkout@v4" "Floating tag is flagged"
    assert_contains "$CUR_VIOLATIONS" "actions/setup-node@49933ea" "SHA without a version comment is flagged"
    assert_contains "$CUR_VIOLATIONS" "some/action@main" "SHA-less ref with a non-version comment is flagged"
    assert_contains "$CUR_VIOLATIONS" "@trailing" "Trailing garbage after the version token is flagged (anchor)"
    # The single valid ref must not appear among the violations. No
    # assert_not_contains in the harness; use a pure-bash glob (no eval).
    local good_flagged=0
    case "$CUR_VIOLATIONS" in
        *"# v4.3.1"$'\n'*) good_flagged=1 ;;
        *"# v4.3.1") good_flagged=1 ;;
    esac
    assert_equals "0" "$good_flagged" "A correctly pinned+commented ref is NOT flagged"
}

# Discover workflow files. nullglob so an empty dir yields an empty array rather
# than a literal glob pattern.
shopt -s nullglob
workflows=("$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml)
shopt -u nullglob

# Guard: the suite must actually inspect something. A gate that silently checks
# zero files/refs (dir moved, glob/grep regressed) is worse than no gate — it
# reports green while enforcing nothing.
total_uses=0
for f in "${workflows[@]}"; do
    c="$(_uses_lines "$f" | command wc -l | command tr -d '[:space:]')"
    total_uses=$((total_uses + c))
done

test_corpus_non_empty() {
    assert_not_empty "${workflows[*]:-}" "At least one workflow file is present to lint"
    if [ "$total_uses" -lt 1 ]; then
        assert_equals "1" "0" "At least one uses: ref must be found across workflows"
    fi
}

run_test test_corpus_non_empty "Workflow corpus is non-empty (gate is not a no-op)"
run_test test_negative_case_fires "scan_file flags unpinned/uncommented/garbage refs (violation path)"

for f in "${workflows[@]}"; do
    CUR_FILE="$f"
    run_test test_file_pins "$(command basename "$f"): actions are SHA-pinned + version-commented"
done

generate_report
