#!/usr/bin/env bash
# READONLY harness-wording guardrail (issue #426).
#
# A nominally read-only reviewer subagent once ran `rm -rf` against the LIVE
# working tree while reproducing a bug — deleting real in-flight worktrees. It
# broke no stated rule: the harness READONLY prompt banned file/VCS mutation
# (edit/write/commit/branch/push) but said nothing about destructive SHELL exec
# (`rm`, `git clean`, `mv`, redirection) and never confined a reproduction to a
# scratch sandbox. Every driven agent holds Bash, so a "read-only" agent could
# delete the repo and stay compliant.
#
# The prompt text was strengthened to ban destructive shell + confine any
# reproduction to a `mktemp -d` sandbox + canonicalize paths (no unresolved
# `..`). Because the Workflow engine has NO module system, that wording is
# copy-duplicated across four read-only prompt constants — nothing keeps them in
# sync. This gate asserts the strengthened wording is present in each, so a
# future edit (or a re-added harness) can't silently drop the guarantee.
#
# The three required fragments each map to one protection and each sits entirely
# within one quoted string segment (the constants are `+`-concatenated across
# lines, so a phrase split across a `' + '` boundary is unmatchable — these are
# not):
#   - `git clean`   the destructive-command ban list
#   - `mktemp -d`   the reproduce-in-a-sandbox confinement
#   - `unresolved`  the canonicalize / never-pass-`..` rule
#
# Only the constant's own block is scanned (not the whole file): `unresolved`
# and `git clean` occur elsewhere in these harnesses for unrelated reasons.
# Pure bash + coreutils + awk + grep; no network. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "READONLY harness wording (#426)"

# The nominally read-only harnesses and the constant each one carries. Flat
# "<relpath>\t<const-name>" rows (no assoc arrays — bash-3.2 clean). This is the
# audited read-only surface from #426; the mutating-agent GUARDRAILS
# (rebase-agent, ci-fixer) are out of scope and intentionally absent.
READONLY_HARNESSES="\
plugins/workflow/skills/ship-issue/workflow.js	READONLY
plugins/dev-core/agents/code-reviewer/workflow.js	READONLY
plugins/review-audit/skills/codebase-audit/workflow.js	READONLY
plugins/workflow/skills/orchestrate/workflow.js	READONLY_POLL"

# The fragments every strengthened read-only constant must contain.
REQUIRED_FRAGMENTS="git clean
mktemp -d
unresolved"

# extract_const_block <file> <const-name> — echo the `const <name> = ...` line
# plus the concatenated string continuation lines that follow it, stopping at the
# first line that does NOT end in a `+` or bare `=` continuation (i.e. the final
# segment of the concatenation). Empty output means the constant was not found.
extract_const_block() {
    local file="$1" name="$2"
    awk -v n="$name" '
        $0 ~ ("^const " n "[[:space:]]*=") { cap = 1 }
        cap { print }
        # Stop after the first line that is not a continuation: a continuation
        # line ends in `+` (more string to come) or the declaration head ends in
        # `=` (string starts next line).
        cap && !/\+[[:space:]]*$/ && !/=[[:space:]]*$/ { exit }
    ' "$file"
}

# missing_fragments_in_block <block> — echo each required fragment NOT present on
# any single line of the block (empty output = all present). grep -F matches
# within a line, so a fragment split across a `' + '` concatenation boundary
# would (correctly) read as missing — the required fragments are chosen to avoid
# that.
missing_fragments_in_block() {
    local block="$1" frag
    while IFS= read -r frag; do
        [ -n "$frag" ] || continue
        printf '%s\n' "$block" | command grep -qF "$frag" || printf '%s\n' "$frag"
    done <<<"$REQUIRED_FRAGMENTS"
}

# Per-row test body (reads CUR_REL / CUR_CONST).
CUR_REL=""
CUR_CONST=""
test_harness_wording() {
    local block missing
    block="$(extract_const_block "$REPO_ROOT/$CUR_REL" "$CUR_CONST")"
    assert_not_empty "$block" \
        "$CUR_REL: const $CUR_CONST not found (renamed or removed? update this gate)"
    missing="$(missing_fragments_in_block "$block")"
    assert_equals "" "$missing" \
        "$CUR_REL: const $CUR_CONST missing strengthened READONLY wording — absent fragment(s): $(printf '%s' "$missing" | command tr '\n' ',' | command sed 's/,$//'). Every read-only prompt must ban destructive shell (\`git clean\`), confine reproduction to a \`mktemp -d\` sandbox, and forbid an \`unresolved\` \`..\` (#426)."
}

# Negative case: the fragment detector must actually fire when a fragment is
# absent, and pass when all are present. Mirrors the two-branch coverage of the
# sibling lints (lint-shell-portability.sh / lint-action-pins.sh).
test_detector_fires() {
    local good bad
    good="  'ban git clean here ' +
  'use a mktemp -d sandbox ' +
  'never pass an unresolved dotdot'"
    assert_equals "" "$(missing_fragments_in_block "$good")" \
        "A block carrying all three fragments reports nothing missing"

    bad="  'ban git clean here ' +
  'never pass an unresolved dotdot'"
    assert_contains "$(missing_fragments_in_block "$bad")" "mktemp -d" \
        "A block missing the sandbox fragment flags 'mktemp -d'"
}

# extract_const_block must isolate the right constant and stop at its terminator
# — a fragment appearing only OUTSIDE the block must not count as present.
test_extractor_bounds() {
    local tmp block
    tmp="$(command mktemp -d)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/fixture.js" <<'EOF'
const OTHER = 'git clean lives here, outside the target constant'
const READONLY =
  'line one of the constant ' +
  'mktemp -d sandbox line'
const AFTER = 'unresolved appears only after the block'
EOF

    block="$(extract_const_block "$tmp/fixture.js" "READONLY")"
    assert_contains "$block" "mktemp -d sandbox line" "Block captures the constant's continuation lines"
    assert_not_contains "$block" "OTHER" "Block excludes a prior constant"
    assert_not_contains "$block" "AFTER" "Block stops at the terminator (excludes the next statement)"
}

# Guard: the row list must be non-empty (a gate that checks zero harnesses is
# worse than no gate).
test_corpus_non_empty() {
    assert_not_empty "$READONLY_HARNESSES" "At least one read-only harness must be listed"
}

run_test test_corpus_non_empty "Read-only harness list is non-empty (gate is not a no-op)"
run_test test_detector_fires "Fragment detector fires on a missing fragment, passes when present"
run_test test_extractor_bounds "Const-block extractor isolates the target constant"

while IFS="$(printf '\t')" read -r rel const; do
    [ -n "$rel" ] || continue
    CUR_REL="$rel"
    CUR_CONST="$const"
    run_test test_harness_wording "$rel :: $const carries strengthened READONLY wording"
done <<<"$READONLY_HARNESSES"

generate_report
