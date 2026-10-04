# shellcheck shell=bash
# golem/SKILL.md Phase A collision guard — prose-contract tests (issue #1119).
#
# #1059 let the worktree collision guard resume an existing `.worktrees/issue-N`
# WITHOUT ASKING, but only when every conjunct holds: a `--level 3|4` flag was
# passed (with no flag the level is unknown in Phase A, so it asks), the worktree
# is on `feature/issue-N`, AND it holds the next-issue state file. Any mismatch
# still asks, at every level. That rule is LLM-followed prose with no runtime to
# unit-test, so dropping one conjunct would widen an unprompted resume into a
# stale or wrong worktree with nothing failing.
#
# ONE TEST PER CONJUNCT, deliberately. A single test matching one phrase stays
# green while a sibling conjunct is deleted; separate tests make each deletion
# fail by name. The block is addressed by contract id via the shared
# extract_contract (tests/lib/harness.sh), which fails loud on a missing or
# duplicated marker, and assert_contract_carries' tamper half proves each token
# is real prose rather than passing vacuously. Tokens are OPERATIVE literals, so
# the rationale around them stays free to be reworded.
#
# Sourced by tests/validate-golem-scripts.sh, which defines GOLEM_SKILL. This
# fragment only DEFINES test functions; the entry point dispatches them.

_GUARD_ID="golem-collision-guard-autoresume"

_guard_region() {
    extract_contract "$_GUARD_ID" "$GOLEM_SKILL"
}

# The outcome the other conjuncts gate. Without it the remaining assertions
# would pin conditions for a behaviour the prose no longer grants.
test_collision_guard_outcome_is_resume_without_asking() {
    local region
    region="$(_guard_region)"
    assert_contract_carries "$_GUARD_ID" "$region" 'resume **without asking**' \
        "collision guard outcome"
}

# Conjunct 1: only an explicit L3/L4 flag unlocks it, and the no-flag case asks.
# Both halves: dropping the second would let an unknown level resume silently.
test_collision_guard_requires_level_flag() {
    local region
    region="$(_guard_region)"
    assert_contract_carries "$_GUARD_ID" "$region" 'Under `--level 3` or `--level 4`' \
        "collision guard flag gate"
    assert_contract_carries "$_GUARD_ID" "$region" \
        'with no flag the level is not yet known here, so it asks' \
        "collision guard no-flag asks"
}

# Conjunct 2: the branch must match. The bold `**and**` is pinned too, so the
# conjunction cannot quietly weaken to "or".
test_collision_guard_requires_branch_match() {
    local region
    region="$(_guard_region)"
    assert_contract_carries "$_GUARD_ID" "$region" 'when the worktree is on `feature/issue-N`' \
        "collision guard branch match"
    assert_contract_carries "$_GUARD_ID" "$region" '**and** holds' \
        "collision guard conjunction"
}

# Conjunct 3: the worktree must hold the next-issue hand-off state file.
test_collision_guard_requires_state_file() {
    local region
    region="$(_guard_region)"
    assert_contract_carries "$_GUARD_ID" "$region" \
        'holds `.claude/memory/tmp/next-issue-N.json`' \
        "collision guard state file"
}

# Conjunct 4: any mismatch falls back to asking — at every level, L4 included.
test_collision_guard_mismatch_still_asks() {
    local region
    region="$(_guard_region)"
    assert_contract_carries "$_GUARD_ID" "$region" 'Any mismatch still asks, at every level' \
        "collision guard mismatch fallback"
}

# The per-conjunct tests above catch a DELETION, but they are substring checks:
# an edit that ADDS words beside an unchanged token keeps every one green —
# "(or `--level 2`)", ", or a stale state file", "at every level except L4" each
# widen the unprompted resume while all four conjuncts are still "present". So
# the operative rule is also pinned EXACTLY, whitespace-normalised (reflowing it
# stays free). Only the text up to the em dash is pinned; the rationale after it
# may be reworded.
test_collision_guard_rule_is_not_widened() {
    local region rule
    region="$(_guard_region)"
    rule="$(command printf '%s\n' "$region" | command tr -s '[:space:]' ' ' |
        command sed -e 's/^ //' -e 's/ — .*$//')"
    assert_equals \
        'Under `--level 3` or `--level 4` it is a routine gate (with no flag the level is not yet known here, so it asks): resume **without asking** when the worktree is on `feature/issue-N` **and** holds `.claude/memory/tmp/next-issue-N.json`. Any mismatch still asks, at every level' \
        "$rule" \
        "collision guard rule is pinned exactly — an insertion widens it"
}
