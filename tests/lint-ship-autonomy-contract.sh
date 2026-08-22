#!/usr/bin/env bash
# Compensating lint for the CC-SK-006 suppression on ship-issue (issue #737).
#
# WHY THIS GATE EXISTS. `.agnix.toml` disables CC-SK-006 (a dangerous skill must
# set `disable-model-invocation`) for plugins/workflow/skills/ship-issue/SKILL.md.
# That suppression is correct and deliberate (#734): `disable-model-invocation:
# true` would break the L3–L4 auto-chain, whose whole point is that the MODEL
# invokes ship-issue in the same turn. But ship-issue commits, pushes, opens PRs,
# and at L3–L4 MERGES — so with the rule off, agnix's only automated check on
# that skill no longer fires anywhere in CI.
#
# What replaced it is the AUTONOMY LEVEL, and .agnix.toml says so in as many
# words: "The real guardrail for this skill is the AUTONOMY LEVEL, not an
# invocation flag." That guardrail is LLM-followed PROSE — a documentation-level
# convention enforced by the model reading the skill body. There is no runtime to
# unit-test. So until now the safety property had nothing but a config comment
# holding it: a future edit loosening the autonomy-level guard would regress
# toward unattended merges with no automated check to notice.
#
# This is therefore a PROSE-CONTRACT gate in the style of
# tests/validate-audit-trust-gate.sh, pinning the three clauses that together ARE
# the compensating control:
#
#   ship-autonomy-level-gates  ship-issue SKILL.md  L1–L2 must STOP for a human merge
#   ship-merge-invariant       ship-issue SKILL.md  never merge un-green/un-reviewed,
#                                                   at EVERY level including L4
#   next-issue-critical-cap    next-issue SKILL.md  severity/critical caps at L3, so a
#                                                   critical issue can never lose the plan gate
#
# ...plus a fourth surface that is not prose at all: the SHAPE of the suppression
# itself in .agnix.toml (see § Suppression scope below).
#
# ADDRESSED BY CONTRACT ID, NEVER BY HEADING OR SENTENCE. Each block carries a
# `<!-- contract: <id> -->` marker and is extracted with the shared
# extract_contract (tests/lib/harness.sh). A heading-pair or sentence-fragment
# anchor would couple this gate to where the prose sits and how it is worded:
# moving a block would break assertions whose guarantee never changed, and
# RENAMING a heading would silently RE-ANCHOR to the wrong region rather than
# fail. Ids fail LOUD on a missing or duplicated marker instead of yielding an
# empty region that every assert_contains would then pass against. assert_contract_carries
# adds the tamper half — stripping the asserted token must demonstrably change
# the region — so no assertion here can pass vacuously.
#
# ASSERT OPERATIVE TOKENS, NOT RATIONALE. Every token below is a literal a
# reader must obey (`L1–L2`, `stop`, `even at L4`, `caps at L3`) rather than a
# sentence explaining why. Rationale must stay free to be reworded; the enforced
# instruction must not.
#
# SCOPE. This gate does NOT re-enable CC-SK-006, and must not be extended to try:
# that trade was made deliberately in #734 and is documented inline in
# .agnix.toml. It also asserts nothing about agnix's own output — that is
# tests/lint-agnix-clean.sh's job, and it needs the binary. This gate is pure
# bash + coreutils over files in the repo, so it runs everywhere, offline, with
# no optional tooling and therefore no skip sentinel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

AGNIX_CONFIG_FILE="$REPO_ROOT/.agnix.toml"

# The rule this gate compensates for, and the one file it may be suppressed on.
SUPPRESSED_RULE="CC-SK-006"
SUPPRESSED_PATH="**/skills/ship-issue/SKILL.md"

# QUOTE-AWARE COMMENT STRIP, shared by both .agnix.toml surfaces below.
#
# Both of them must ignore `#` comments — this config discusses CC-SK-006 at
# length in prose, so a raw match would fire on the documentation OF the property
# rather than the property (see each test for its own version of that trap). But
# a bare `sub(/#.*/, "")` is wrong in the other direction: TOML permits `#`
# INSIDE a quoted value, and truncating there silently discards the rest of the
# line. A mutation round confirmed the consequence — a second suppressed path
# `"**/skills/gh#issue/SKILL.md"` on the same line as ship-issue's made the whole
# tail vanish before the path count ever saw it, so a second dangerous skill was
# suppressed with the gate still green.
#
# So: walk the line, track whether we are inside a double-quoted span, and cut
# only at a `#` outside one. TOML basic strings permit `\"`, so a quote preceded
# by an odd run of backslashes does not close the span. Deliberately no support
# for literal ('') or multi-line (""") strings — this file uses neither, and the
# `[[overrides]]`-block assertions below would fail loudly rather than silently
# if it ever grew one.
AWK_STRIP_COMMENT='
function strip_comment(line,    i, c, out, in_str, bs) {
    out = ""; in_str = 0
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "#" && !in_str) { return out }
        if (c == "\"") {
            # count the contiguous backslashes immediately before this quote
            bs = 0
            while (i - 1 - bs >= 1 && substr(line, i - 1 - bs, 1) == "\\") { bs++ }
            if (bs % 2 == 0) { in_str = !in_str }
        }
        out = out c
    }
    return out
}
'

test_suite "ship-issue autonomy-level contract (#737)"

# Contract blocks are addressed BY ID, resolved anywhere under plugins/, so this
# gate never names the file a clause lives in. A clause that MOVES between files
# needs no edit here — only DELETING its marker breaks the gate, which is exactly
# the change that should break it.
# shellcheck disable=SC2034  # read by extract_contract in the sourced harness
CONTRACT_SEARCH_ROOT="$REPO_ROOT/plugins"

# --- Surface 1: L1–L2 must stop for a human merge ---------------------------
# The level→gate dispatch table. The load-bearing half is the L1–L2 row: those
# levels STOP at green+clean and a human merges. If a future edit collapsed that
# row into the L3–L4 auto-merge behaviour, every level would merge unattended —
# the precise regression CC-SK-006 would have flagged.
test_l1_l2_stops_for_human_merge() {
    local region
    region="$(extract_contract ship-autonomy-level-gates)"

    assert_contract_carries ship-autonomy-level-gates "$region" '**L1–L2**' \
        "ship dispatch table"
    assert_contract_carries ship-autonomy-level-gates "$region" '**stop**' \
        "ship dispatch table"
    assert_contract_carries ship-autonomy-level-gates "$region" 'human merges' \
        "ship dispatch table"

    # The counterpart row must still exist, so the table is genuinely a
    # per-level SPLIT and not a single uniform behaviour that happens to mention
    # the L1–L2 tokens above.
    assert_contains "$region" '**L3–L4**' \
        "ship dispatch table: still distinguishes L3–L4 from L1–L2"
    assert_contains "$region" 'auto-merge' \
        "ship dispatch table: names auto-merge as the L3–L4-only behaviour"
}

# --- Surface 2: the merge invariant binds every level, L4 included ----------
# The level decides whether merging needs a human keystroke — never whether an
# un-green or un-reviewed PR may merge. `even at L4` is the operative token: it
# is what stops "autonomous" from being read as "may merge red".
test_merge_invariant_binds_all_levels() {
    local region
    region="$(extract_contract ship-merge-invariant)"

    assert_contract_carries ship-merge-invariant "$region" 'even at L4' \
        "merge invariant"

    # The dead-end ESCAPE, asserted by what it makes the run DO rather than by
    # the words "dead-end". A mutation round found the bare term survivable: it
    # occurs three times in this paragraph (once as the classification, twice in
    # a cross-reference to `§ dead-end rule` and `the dead-end summary`), so
    # gutting the operative sentence still left the token behind and the
    # assertion still passed. `park the PR` and `wait for a human` each occur
    # once, in the sentence that actually specifies the behaviour.
    assert_contract_carries ship-merge-invariant "$region" 'park the PR' \
        "merge invariant"
    assert_contract_carries ship-merge-invariant "$region" 'wait for a' \
        "merge invariant"

    # Both halves of the precondition, on one flattened line: the paragraph wraps
    # `CI is green` / `the PR review loop terminated clean` across line breaks, so
    # a raw substring match would miss them.
    local flat
    flat="$(command printf '%s' "$region" | command tr -s '[:space:]' ' ')"
    assert_contains "$flat" 'Never merge unless CI is green' \
        "merge invariant: CI-green is a precondition of merging"
    assert_contains "$flat" 'review loop terminated clean' \
        "merge invariant: a clean review loop is a precondition of merging"
}

# --- Surface 3: a critical issue can never lose the plan gate ---------------
# severity/critical caps the level at L3, and L3 keeps the plan gate. That cap is
# what guarantees the highest-stakes issues always route through a human before
# implementation, whatever `--level` was passed.
test_critical_caps_at_l3() {
    local region
    region="$(extract_contract next-issue-critical-cap)"

    # The WHOLE clause, not the fragment `caps at L3`. A mutation round found the
    # fragment survivable: it also appears further down the same region ("Because
    # critical caps at L3, a critical issue always keeps the gate"), so raising
    # the actual cap to L4 in the normative sentence left the fragment behind and
    # the assertion passed on a config that had lost the property.
    assert_contract_carries next-issue-critical-cap "$region" \
        'A `severity/critical` issue **caps at L3**.' "critical cap"

    # The cap is only a safety property because L3 keeps the plan gate; assert
    # the region still says so, rather than leaving the two facts in files that
    # could drift apart.
    local flat
    flat="$(command printf '%s' "$region" | command tr -s '[:space:]' ' ')"
    assert_contains "$flat" 'kept at **L1–L3**' \
        "critical cap: the plan gate is kept at L1–L3"
    assert_contains "$flat" 'a critical issue always keeps the gate' \
        "critical cap: states the consequence — a critical issue keeps the plan gate"
}

# --- Surface 4: the suppression stays narrowly scoped -----------------------
# .agnix.toml already calls this distinction load-bearing: "a global disable
# would forfeit its protection for every OTHER skill, which is the protection
# worth keeping." Nothing enforced it until now — and per this repo's
# comment-asserts-intent lesson, a comment claiming a property the code does not
# have is worse than no comment, because it tells the next reader it is handled.
#
# Two regressions, both silent:
#   1. CC-SK-006 migrating into the global `disabled_rules` list, forfeiting the
#      rule for every other skill in the marketplace while this file still reads
#      as a narrow per-file exception.
#   2. The override's `paths` growing beyond ship-issue's SKILL.md, so a NEW
#      dangerous skill is suppressed by inheritance rather than by a decision.
test_suppression_is_per_file_not_global() {
    assert_file_exists "$AGNIX_CONFIG_FILE" ".agnix.toml exists"

    # The global list is a `disabled_rules = [...]` assignment at top level;
    # per-file suppressions use the SAME key inside an `[[overrides]]` block. So
    # the global one is identified by position: before the first `[[overrides]]`
    # header.
    #
    # COMMENTS ARE STRIPPED FIRST, and that is not incidental. This very file
    # discusses CC-SK-006 at length in prose above the overrides — including the
    # sentence explaining why a global disable would be wrong. Matching raw text
    # would find the rule in that explanation and fail on a correct config: an
    # assertion that fires on the documentation OF the property rather than the
    # property. Only assignments are code here.
    local global_assignments
    global_assignments="$(command awk "$AWK_STRIP_COMMENT"'
        /^\[\[overrides\]\]/ { exit }
        { print strip_comment($0) }
    ' "$AGNIX_CONFIG_FILE")"

    assert_not_contains "$global_assignments" "$SUPPRESSED_RULE" \
        "$SUPPRESSED_RULE must NOT appear in the global [rules] disabled_rules — a global disable forfeits the rule for every other skill"

    # Prove the extract is real rather than an empty string that trivially
    # "does not contain" the rule: the two genuinely-global disables must be
    # visible in it.
    assert_contains "$global_assignments" 'disabled_rules' \
        "global [rules] disabled_rules assignment is present in the extract (assertion targets real config)"
    assert_contains "$global_assignments" 'CC-MEM-014' \
        "the extract carries the real global disables (so the CC-SK-006 absence above is meaningful)"

    # ...and it must still be suppressed SOMEWHERE, or this gate is guarding a
    # suppression that no longer exists and all three prose surfaces above are
    # compensating for nothing. (If CC-SK-006 is ever genuinely re-enabled for
    # ship-issue, delete this gate deliberately rather than letting it pass on a
    # config it no longer describes.)
    assert_file_contains "$AGNIX_CONFIG_FILE" "$SUPPRESSED_RULE" \
        "$SUPPRESSED_RULE is still suppressed in .agnix.toml (this gate compensates for it)"
}

test_suppression_names_only_ship_issue() {
    # The [[overrides]] block carrying CC-SK-006 must name ship-issue's SKILL.md
    # and nothing else. Read the file into blocks split on `[[overrides]]`, keep
    # the one mentioning the rule, and count its `paths` entries.
    #
    # Pure awk rather than a TOML parser: this repo's gates stay dependency-free,
    # and the question — "how many quoted paths sit in the block naming this
    # rule" — does not need one.
    #
    # Comments are stripped here for the same reason as in the global check
    # above: the prose introducing these blocks names CC-SK-006, so a raw match
    # would select the WRONG block (the XML-001 one, whose header comment
    # discusses the rule) and then count its three paths.
    local block
    block="$(command awk -v rule="$SUPPRESSED_RULE" "$AWK_STRIP_COMMENT"'
        { $0 = strip_comment($0) }
        /^\[\[overrides\]\]/ { block = ""; in_block = 1 }
        in_block { block = block $0 "\n" }
        /^disabled_rules/ && in_block {
            if (index(block, rule) > 0) { print block; exit }
            in_block = 0
        }
    ' "$AGNIX_CONFIG_FILE")"

    assert_not_empty "$block" \
        "$SUPPRESSED_RULE must live in an [[overrides]] block (per-file), not as a bare global entry"

    # Extract every quoted glob in the block, one per line, unquoted. Both
    # assertions below read this list — the identity check and the count — so
    # they cannot disagree about what "the paths" are.
    #
    # `grep -o` (not `grep -c` on the raw block): `-c` reports matching LINES,
    # and TOML permits `paths = ["a", "b"]` on ONE line — the very shape this
    # override uses — so a line count returns 1 for any number of paths. A
    # mutation round caught exactly that: a second skill appended to the same
    # line survived.
    local paths
    paths="$(command printf '%s\n' "$block" | command grep -oE '"\*\*/[^"]*"' |
        command tr -d '"')"

    # EXACT identity, not substring containment. `assert_contains` would accept
    # any path that merely CONTAINS this one, so a single path silently widening
    # to `**/skills/ship-issue/SKILL.mdx` (or `...SKILL.md-backup`) would pass —
    # the path count is still 1, and the literal is still in there. A mutation
    # round confirmed it: renaming the suppressed file to `SKILL.mdx` left all
    # six tests green. Comparing the whole extracted list to the expected path
    # closes both halves at once — a drifted path fails the equality, and an
    # ADDED path makes the list multi-line and fails it too.
    assert_equals "$SUPPRESSED_PATH" "$paths" \
        "the $SUPPRESSED_RULE override must name EXACTLY ship-issue's SKILL.md and nothing else (found: $(command printf '%s' "$paths" | command tr '\n' ' ')) — a new dangerous skill must be suppressed by decision, not by inheritance"

    # The count, asserted separately so a failure says WHICH way it broke: the
    # equality above already rejects a second path, but reports it as a mismatched
    # string rather than as "two paths where one was expected".
    local path_count
    path_count="$(command printf '%s\n' "$paths" | command grep -c . || true)"
    assert_equals "1" "$path_count" \
        "the $SUPPRESSED_RULE override must name exactly ONE path (found $path_count)"
}

# --- Corpus sanity: the markers this gate depends on are real ---------------
# extract_contract already fails loud on a missing or duplicated id, so the three
# surfaces above cannot pass against an empty region. What it cannot catch is a
# marker drifting INDENTED — and the two marker kinds fail differently:
#
#   START marker indented -> extract_contract cannot find the id and FATALs.
#     Loud, though the message blames a missing contract rather than the
#     whitespace that actually moved.
#   END marker indented -> extract_contract's terminator test is
#     `index($0, "<!-- contract:") == 1` (harness.sh), so an indented end marker
#     does NOT stop the region. The region silently OVER-GROWS into whatever
#     prose follows, and every assertion above still passes — an over-grown
#     region still CONTAINS its tokens, and assert_contract_carries' tamper half
#     only proves the token is really there, not that the region ended where it
#     should. That is precisely the vacuous pass this gate exists to preclude,
#     so the END markers must be pinned too, not just the ids naming the regions.
#     Verified by mutation: indenting `end-ship-merge-invariant` by two spaces
#     left all six tests green before this loop covered it.
#
# `ship-autonomy-level-gates` needs no end marker of its own — it is terminated
# by `ship-merge-invariant`'s START marker, which this loop already pins.
test_markers_are_line_initial() {
    local id
    for id in ship-autonomy-level-gates ship-merge-invariant next-issue-critical-cap \
        end-ship-merge-invariant end-next-issue-critical-cap; do
        local hits
        hits="$(command grep -rlF "<!-- contract: ${id} -->" "$CONTRACT_SEARCH_ROOT" \
            --include='*.md' 2>/dev/null || true)"
        assert_not_empty "$hits" "contract marker '$id' exists somewhere under plugins/"

        local line_initial
        line_initial="$(command grep -rhF "<!-- contract: ${id} -->" "$CONTRACT_SEARCH_ROOT" \
            --include='*.md' 2>/dev/null | command grep -c "^<!-- contract: ${id} -->" || true)"
        assert_equals "1" "$line_initial" \
            "contract marker '$id' must start at column 0 (found $line_initial line-initial occurrences) — an indented START marker is invisible to extract_contract; an indented END marker silently over-grows the region"
    done
}

run_test test_l1_l2_stops_for_human_merge "L1–L2 stop for a human merge (ship dispatch table)"
run_test test_merge_invariant_binds_all_levels "Merge invariant binds every level, L4 included"
run_test test_critical_caps_at_l3 "severity/critical caps at L3, keeping the plan gate"
run_test test_suppression_is_per_file_not_global "CC-SK-006 suppression is per-file, never global"
run_test test_suppression_names_only_ship_issue "CC-SK-006 override names only ship-issue's SKILL.md"
run_test test_markers_are_line_initial "Contract markers are line-initial and unique"

generate_report
