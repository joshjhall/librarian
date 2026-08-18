#!/usr/bin/env bash
# agnix → checker wiring contract (issue #401).
#
# ADR plugins/review-audit/docs/adr/0001-agnix-check-ai-config-boundary.md §2/§4
# makes the external agnix linter an OPTIONAL enrichment over the always-present
# check-ai-config floor. Issue #397 shipped the executable boundary object
# (agnix-normalize.{py,sh}, pinned by tests/validate-agnix-normalize.sh). Issue
# #401 — the change THIS gate guards — wires the `checker` agent
# (plugins/review-audit/agents/checker.md) to that normalizer:
#
#   Step 3a  invoke agnix-normalize as a SECOND pre-scan source (check-ai-config
#            only), absent-agnix => skip its contribution (same graceful-degrade
#            shape as the patterns.sh non-zero/malformed => continue path)
#   Step 6   precedence dedup (#402 down-scope) — an agnix CC-* finding supersedes
#            the check-ai-config finding for the SAME underlying issue, keyed on
#            same-`file` + same owned-category (NOT file:line — the floor anchors
#            frontmatter at whole-file line 1), matched PER ISSUE so a sibling
#            finding agnix did not report survives (never deletes coverage agnix
#            lacks). ONLY for the agnix-OWNED categories (ADR §3); claude-md-drift /
#            config-inconsistency stay check-ai-config-exclusive and are kept-both.
#            Keyed on ACTUAL agnix output present this run (strict no-op when agnix
#            did not run).
#   Trust    the audited repo's .agnix.toml is untrusted => an ENFORCED skip-gate:
#            when AGNIX_CONFIG is unset AND CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS!=1
#            the checker does NOT invoke agnix (else agnix discovers the repo's
#            own .agnix.toml) — mirroring the other three trust surfaces.
#   Observe  never run agnix --fix / --fix-safe / --fix-unsafe (checker is
#            contractually observe-only) — pinned in BOTH the top-level MUST-NOT
#            list and Step 3a's own bullet.
#
# checker.md is LLM-FOLLOWED PROSE, not executable shell — there is no runtime to
# unit-test — so this is a PROSE-CONTRACT / drift gate in the exact style of
# tests/validate-audit-trust-gate.sh: each acceptance criterion gets a live
# assertion (the anchored region carries the wired tokens) plus a tamper guard
# (stripping the wired line demonstrably changes the region), so a live assertion
# can never pass against an empty / wrongly-anchored extract.
#
# Pure bash + coreutils; no node/jq. Full /usr/bin/* paths per project shell
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

CHECKER="$REPO_ROOT/plugins/review-audit/agents/checker.md"

# Contract blocks are addressed BY ID and resolved anywhere under plugins/, so
# this gate does not care which file carries them. #503 moved the whole agnix
# sub-step out of checker.md into
# plugins/review-audit/skills/check-ai-config/agnix-prescan.md without a single
# assertion below changing — that is the property this addressing buys.
# shellcheck disable=SC2034  # read by extract_contract in the sourced harness
CONTRACT_SEARCH_ROOT="$REPO_ROOT/plugins"

# WHY IDS, NOT HEADING PAIRS. This gate previously anchored each region on two
# heading strings (`extract_between "$CHECKER" '#### Step 3a:' '### Step 4:'`)
# and asserted ~40 English prose fragments inside them. That coupled every
# assertion to where the prose sat and how it was worded:
#
#   * moving the block broke all 81 assertions though the guarantee was intact;
#   * renaming a heading silently RE-ANCHORED instead of failing, so a region
#     could run past its intended end and swallow unrelated prose — which is why
#     the old code needed hand-maintained STEP3A_MAX_LINES / STEP6_MAX_LINES
#     bounds purely to notice;
#   * Step 3a's heading was ALSO the END sentinel of a region in
#     validate-audit-trust-gate.sh, so moving it expanded that gate's region as
#     a side effect.
#
# extract_contract (tests/lib/harness.sh) addresses a block by an id embedded in
# the prose, and both MAX_LINES bounds are gone with it: an id-delimited span
# cannot run away, so there is nothing to bound. Assertions now target OPERATIVE
# tokens — the literals a reader must obey (`AGNIX_CONFIG`, `--fix-unsafe`, the
# `[prescan]` log formats) — rather than rationale sentences, so the reasoning
# prose is free to be rewritten while the enforced instruction stays pinned.

test_suite "agnix → checker wiring (#401)"

# assert_wired LABEL REGION TOKEN — the region carries TOKEN and TOKEN is
# genuinely present (stripping it changes the region). Now a thin alias over the
# shared assert_contract_carries in tests/lib/harness.sh; kept so the assertion
# bodies below read unchanged.
#
# The old MAX_LINES parameter is gone. It existed to detect a heading anchor that
# had matched the wrong place and run away past its END sentinel — a failure mode
# an id-delimited region cannot have, since a region ends at the next marker or
# EOF by construction. Callers that passed a bound no longer do.
assert_wired() {
    assert_contract_carries "region" "$2" "$3" "$1"
}

# agnix_prescan_region — the whole agnix pre-scan contract, as one string.
#
# What used to be a single heading-delimited "Step 3a" is now five separately
# addressable contract blocks (invocation, trust posture, observe-only, owned
# categories, graceful degrade). Assertions that pin a token anywhere in the
# sub-step concatenate them; assertions that must prove a token sits in a
# SPECIFIC block address that block by id directly.
#
# Concatenation is deliberate for the broad ones: their claim is "this guarantee
# is stated somewhere in the agnix contract", and splitting them across five
# ids would assert a prose LAYOUT the gate has no business fixing.
agnix_prescan_region() {
    extract_contract agnix-prescan-framing
    extract_contract agnix-prescan-invocation
    extract_contract agnix-trust-posture
    extract_contract agnix-observe-only
    extract_contract agnix-owned-categories
    extract_contract agnix-graceful-degrade
}

# AC1 — Step 3a invokes agnix-normalize as a second pre-scan source over the same
# manifest, logs a discovery line, and carries its own observe-only bullet.
test_step3a_invocation() {
    assert_file_exists "$CHECKER" "checker.md exists"
    local region
    region="$(agnix_prescan_region)"
    assert_wired "Step 3a invocation" "$region" 'agnix-normalize.sh <tempfile>'
    assert_contains "$region" 'second' \
        "Step 3a invocation: framed as a SECOND pre-scan source"
    # Discovery log line — pinned like every other pre-scan surface in
    # validate-audit-trust-gate.sh.
    assert_contains "$region" '[prescan] agnix enrichment' \
        "Step 3a invocation: pins the discovery log-line format"
    # Step 3a's OWN observe-only bullet — the operative instruction the LLM reads
    # at the point it invokes agnix, distinct from the top-level MUST-NOT list.
    assert_contains "$region" 'Observe-only — never autofix' \
        "Step 3a invocation: carries its own observe-only bullet"
    assert_contains "$region" 'do not add any fix flag' \
        "Step 3a invocation: Step-3a-local no-fix-flag instruction present"
}

# AC1 — graceful degrade: absent agnix => skip its contribution, same shape as
# the patterns.sh failure path (continue without pre-scan results, do not drop).
test_step3a_graceful_degrade() {
    local region
    region="$(extract_contract agnix-graceful-degrade)"
    assert_wired "Step 3a graceful degrade" "$region" 'skip its contribution'
    assert_contains "$region" 'identical to today' \
        "Step 3a graceful degrade: absent agnix => output identical to today"
    assert_contains "$region" 'do NOT drop the skill' \
        "Step 3a graceful degrade: never drops check-ai-config on agnix failure"
}

# AC — trust posture: an ENFORCED skip-gate (not descriptive advice). When
# AGNIX_CONFIG is unset and trust is not opted in, the checker must NOT invoke
# agnix — else agnix discovers the audited repo's own .agnix.toml.
test_step3a_trust() {
    local region
    region="$(extract_contract agnix-trust-posture)"
    assert_wired "Step 3a trust" "$region" 'AGNIX_CONFIG'
    assert_contains "$region" 'untrusted input' \
        "Step 3a trust: the audited repo .agnix.toml is untrusted input"
    assert_contains "$region" 'CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1' \
        "Step 3a trust: gated by the same project-trust opt-in as the other surfaces"
    # The trust posture must be ENFORCED, not descriptive: when AGNIX_CONFIG is
    # unset and trust is not opted in, DO NOT invoke agnix (else it discovers the
    # audited repo's own .agnix.toml).
    assert_contains "$region" 'do NOT invoke the normalizer for this run' \
        "Step 3a trust: enforces skip when no operator config and no opt-in"
    assert_contains "$region" '[prescan] agnix skipped (no operator-controlled AGNIX_CONFIG' \
        "Step 3a trust: logs the enforced-skip line"

    # #472 item 2 — the two INVOKE branches, previously unpinned (only the
    # security-critical skip branch above was asserted, so branches (1) and (3)
    # could be garbled without this gate noticing).
    assert_contains "$region" 'invoke the normalizer with it inherited' \
        "Step 3a trust: branch 1 (AGNIX_CONFIG set) invokes with the operator config inherited"
    assert_contains "$region" 'operator explicitly trusts this repo' \
        "Step 3a trust: branch 3 (unset + opted in) invokes as the opted-in behavior"
}

# #471 — the trust hazard is NOT the config the checker reads, it is the one
# AGNIX reads behind it. agnix's default discovery walks up from EACH scanned
# file's own directory (verified against the pinned 0.40.0 and 0.41.0), so a
# hostile repo can plant an .agnix.toml at any depth and a repo-root-only check
# never sees it. The only reliable defense is to ALWAYS pass an explicit
# --config, which suppresses the walk entirely. Pin that invariant so a future
# edit cannot regress to "skip when the root file is untracked" — which reads as
# safe but silently leaves every nested planted config live.
test_step3a_config_pinning() {
    local region
    region="$(extract_contract agnix-trust-posture)"
    # Single-line fragments throughout: the prose wraps, so anchor on the half
    # that fits one source line.
    assert_wired "Step 3a config pinning" "$region" \
        'agnix ALWAYS runs with an'

    # The mechanism — why a repo-root-only check is insufficient.
    assert_contains "$region" 'walks up from each scanned' \
        "Step 3a config pinning: states agnix discovery walks up per-file"
    assert_contains "$region" 'any** directory near the files' \
        "Step 3a config pinning: names the nested-plant attack a root check would miss"
    assert_contains "$region" 'suppresses the upward walk' \
        "Step 3a config pinning: explicit --config is what neutralizes discovery"

    # The opted-in branch ALWAYS uses a checker-owned config — it never reads the
    # repo's own .agnix.toml at all. Pin the literal required key and the
    # out-of-tree constraint: a malformed or missing default config would make
    # agnix fall back to its own discovery, reopening the nested-plant hole this
    # whole posture exists to close.
    assert_contains "$region" 'checker-controlled config' \
        "Step 3a config pinning: the opt-in branch uses a checker-owned default config"
    assert_contains "$region" 'tools = ["claude-code"]' \
        "Step 3a config pinning: pins the default config's required key literally"
    assert_contains "$region" 'never inside the audited' \
        "Step 3a config pinning: the default config is written outside the audited tree"
    assert_contains "$region" '[prescan] agnix pinned to default config' \
        "Step 3a config pinning: logs the default-config pin"
    assert_contains "$region" 'validate, or point agnix at the repo' \
        "Step 3a config pinning: forbids reading the repo's own .agnix.toml outright"

    # #548 — the ban is UNCONDITIONAL, and that is the load-bearing half. The
    # assertion above stops one line short of the qualifier that says so, so an
    # edit re-narrowing the ban to a trigger condition (the repo config being
    # absent / untracked / unreadable) would pass every other assertion here.
    # #547 replaced exactly such a conditional fallback with this unconditional
    # posture; pin both halves so it cannot drift back.
    #
    # Traceability for #548's literal wording (#563): #548 asked to pin the
    # `unreadable` DISJUNCT, but that word has never existed in checker.md --
    # `git log --all -S unreadable -- plugins/review-audit/agents/checker.md`
    # returns no commits, and the current file contains it zero times. #547 had
    # already collapsed the conditional fallback, so there was no disjunct left
    # to pin verbatim. #548 is therefore satisfied by the two assertions that
    # follow: the positive pin on the SURVIVING unconditional qualifier
    # (`, tracked or not.`), plus the negative guard below. Note the word does
    # appear in this function -- in the trigger loop -- but only as a BANNED
    # word asserted absent from the opted-in branch, never as the pinned
    # subject. Do not read that loop entry as #548's disjunct.
    assert_contains "$region" 'tracked or not' \
        "Step 3a config pinning: the do-not-read ban is unconditional (tracked or not)"

    # Negative half of the same guard: the positive pin above still admits an
    # edit that ADDS a precondition alongside it. Scope to the opted-in branch
    # and assert no absence/trackedness/readability trigger appears there. The
    # sub-region deliberately ENDS before "Why not honor a tracked" — that
    # rationale paragraph legitimately discusses trackedness, as does the
    # graceful-degrade text later in the region, so a whole-region check would
    # be vacuous. assert_not_empty guards the narrowing itself: a renamed anchor
    # fails loudly instead of passing against an empty extract.
    local opted_in
    opted_in="$(printf '%s\n' "$region" |
        command awk '/operator explicitly trusts this repo/{g=1} g&&/Why not honor a tracked/{exit} g')"
    assert_not_empty "$opted_in" \
        "Step 3a config pinning: opted-in branch sub-region extracted"
    local trigger
    for trigger in absent untracked unreadable readable; do
        assert_not_contains "$opted_in" "$trigger" \
            "Step 3a config pinning: the opted-in ban is not re-conditioned on '$trigger'"
    done

    # WHY the repo's own config is never honored, even when git-tracked. Both
    # bypasses are reproduced (0.40.0 + 0.41.0) and both are ls-files-clean, so
    # keep the rationale wired — a future edit that "restores" a tracked-file
    # branch would silently reopen them.
    assert_contains "$region" 'vouch for what a config resolves to' \
        "Step 3a config pinning: states tracked-ness does not vouch for content"
    assert_contains "$region" 'index mode `120000`' \
        "Step 3a config pinning: names the tracked-symlink bypass"
    assert_contains "$region" '`extend` key' \
        "Step 3a config pinning: names the extend-chain bypass"
    assert_contains "$region" 'no attacker-authored input on this path' \
        "Step 3a config pinning: pins the principle — remove the class, don't validate it"

    # The load-bearing distinction from the sibling surfaces: skipping is NOT
    # sufficient here. Keep the rationale wired so a future reader does not
    # "restore parity" with the other three guards and reopen the hole.
    assert_contains "$region" 'skipping is not enough here' \
        "Step 3a config pinning: states why skip-on-untrusted is insufficient at this surface"
    assert_contains "$region" 'Neutralize the input rather than declining to run' \
        "Step 3a config pinning: pins the neutralize-not-skip principle"
}

# #472 item 1 — the four-item agnix-owned category list is duplicated in Step 3a
# (collection) and Step 6 (precedence dedup) and MUST stay in sync;
# test_step6_precedence_dedup only asserts the literal phrase "Agnix-owned
# categories are exactly", never the names themselves nor that the two lists
# agree. Extract the tokens from both regions and compare the sets.
test_owned_category_parity() {
    local step3a step6 cats_3a cats_6 expected
    step3a="$(agnix_prescan_region)"
    step6="$(extract_contract agnix-step6-precedence)"
    assert_not_empty "$step3a" "owned-category parity: Step 3a region extracted"
    assert_not_empty "$step6" "owned-category parity: Step 6 region extracted"

    # ADR §3 ownership table — the canonical four.
    expected="$(printf 'agent-frontmatter\nhook-safety\nmcp-misconfiguration\nskill-frontmatter\n')"

    # Scope the extraction to each region's ENUMERATION sentence, not the whole
    # region. Both regions mention the owned categories incidentally elsewhere
    # (Step 6 names `hook-safety` three times: the Guard-2 rationale, the
    # per-issue-match example, and the enumeration), so a whole-region grep +
    # `sort -u` would still see a token whose enumeration entry was deleted —
    # i.e. it would pass through exactly the drift this test exists to catch.
    # Each enumeration is an anchor phrase plus the ~3 wrapped lines that follow.
    local enum_3a enum_6
    enum_3a="$(printf '%s\n' "$step3a" | command grep -A3 -F 'ownership table assigns to agnix')"
    enum_6="$(printf '%s\n' "$step6" | command grep -A3 -F 'Agnix-owned categories are exactly')"
    assert_not_empty "$enum_3a" \
        "owned-category parity: Step 3a enumeration sentence located"
    assert_not_empty "$enum_6" \
        "owned-category parity: Step 6 enumeration sentence located"

    cats_3a="$(printf '%s\n' "$enum_3a" |
        command grep -oE 'agent-frontmatter|skill-frontmatter|hook-safety|mcp-misconfiguration' |
        command sort -u)"
    cats_6="$(printf '%s\n' "$enum_6" |
        command grep -oE 'agent-frontmatter|skill-frontmatter|hook-safety|mcp-misconfiguration' |
        command sort -u)"

    # Plain bash comparison (NOT assert_true, which eval's its argument).
    local match_3a="no" match_6="no" match_each="no"
    [ "$cats_3a" = "$expected" ] && match_3a="yes"
    [ "$cats_6" = "$expected" ] && match_6="yes"
    [ "$cats_3a" = "$cats_6" ] && match_each="yes"

    assert_equals "yes" "$match_3a" \
        "owned-category parity: Step 3a enumerates exactly the ADR §3 four"
    assert_equals "yes" "$match_6" \
        "owned-category parity: Step 6 enumerates exactly the ADR §3 four"
    assert_equals "yes" "$match_each" \
        "owned-category parity: the Step 3a and Step 6 lists are identical (no drift)"

    # The check-ai-config-exclusive pair must be named in BOTH regions as the
    # excluded categories (ADR §1/§3) — their absence would mean the exclusion
    # rule went missing, which the precedence dedup depends on.
    assert_contains "$step3a" 'config-inconsistency' \
        "owned-category parity: Step 3a names config-inconsistency as NOT agnix-owned"
    assert_contains "$step6" 'claude-md-drift' \
        "owned-category parity: Step 6 names claude-md-drift as NOT agnix-owned"
}

# AC — observe-only: the top-level MUST-NOT restriction list bans agnix autofix,
# naming all three flags.
test_observe_only_restriction() {
    local region
    region="$(extract_contract checker-must-not)"
    assert_wired "observe-only restriction" "$region" 'Run agnix in any autofix mode'
    assert_contains "$region" '--fix-unsafe' \
        "observe-only restriction: names the --fix-unsafe autofix flag"
    assert_contains "$region" '--fix-safe' \
        "observe-only restriction: names the --fix-safe autofix flag"
    assert_contains "$region" '`--fix`' \
        "observe-only restriction: names the bare --fix autofix flag"
}

# AC2 — precedence dedup at the merge step (#402 down-scope): an agnix-owned-category
# CC-* finding supersedes the check-ai-config finding for the SAME underlying issue,
# keyed on same-`file` + same-category (NOT file:line — the floor anchors frontmatter
# at whole-file line 1), matched PER ISSUE so a sibling finding agnix did not report
# survives (never deletes coverage agnix lacks — the crux of #402's "NOT deletion").
# ONLY for agnix-owned categories; strict no-op when agnix did not run; ordering
# before within-skill dedup.
test_step6_precedence_dedup() {
    local region
    region="$(extract_contract agnix-step6-precedence)"
    assert_wired "Step 6 precedence dedup" "$region" 'agnix precedence dedup'
    # #402: the dedup KEY is same-file + same-category matched PER ISSUE, NOT
    # file:line and NOT whole-category — a file:line key silently misses the floor's
    # line-1-anchored frontmatter overlap, while a whole-category sweep would delete
    # sibling findings agnix never reported.
    assert_contains "$region" 'Match per underlying issue on same-`file` + same-category' \
        "Step 6 precedence dedup: keyed per-issue on same-file + same-category"
    assert_contains "$region" 'NOT on `file:line`' \
        "Step 6 precedence dedup: explicitly NOT keyed on file:line"
    assert_contains "$region" 'NOT on the whole category at once' \
        "Step 6 precedence dedup: explicitly NOT a whole-category sweep"
    assert_contains "$region" 'sentinel line `1`' \
        "Step 6 precedence dedup: rationale — floor anchors whole-file findings at line 1"
    assert_contains "$region" 'actual field line' \
        "Step 6 precedence dedup: rationale — agnix reports the real field line"
    assert_contains "$region" 'silently miss' \
        "Step 6 precedence dedup: a file:line key would silently miss the frontmatter overlap"
    # The load-bearing NOT-deletion guarantee: multiple findings per file+category,
    # drop ONLY the matched issue, retain siblings agnix did not cover.
    assert_contains "$region" 'multiple distinct findings per file+category' \
        "Step 6 precedence dedup: acknowledges the floor emits multiple findings per file+category"
    assert_contains "$region" 'Do NOT collapse the whole file+category at once' \
        "Step 6 precedence dedup: forbids the whole-category collapse"
    assert_contains "$region" 'never deletes coverage agnix lacks' \
        "Step 6 precedence dedup: preserves the NOT-deletion guarantee (#402 core mandate)"
    assert_contains "$region" 'drop the' \
        "Step 6 precedence dedup: drops the superseded check-ai-config finding"
    assert_contains "$region" 'strict no-op' \
        "Step 6 precedence dedup: strict no-op when agnix did not run"
    assert_contains "$region" 'always retained' \
        "Step 6 precedence dedup: non-overlapping check-ai-config findings retained"
    # Ordering constraint is load-bearing.
    assert_contains "$region" 'before** the within-skill' \
        "Step 6 precedence dedup: pins the before-within-skill-dedup ordering"
    # Owned-category scoping: claude-md-drift / config-inconsistency are
    # check-ai-config-exclusive (ADR §3) and must NOT be dropped — keep both.
    assert_contains "$region" 'Agnix-owned categories are exactly' \
        "Step 6 precedence dedup: enumerates the agnix-owned categories"
    assert_contains "$region" 'keep **both**' \
        "Step 6 precedence dedup: keeps both for check-ai-config-exclusive categories"
    # Regression guard: the pre-#402 file:line-keyed phrasing must not reappear as
    # the dedup KEY. The only licensed occurrence of the "same `file:line`" phrase in
    # the region is the explicit "NOT on `file:line`" negation; assert the affirmative
    # "at the same `file:line`" / "fire at the same `file:line`" key phrasing is gone,
    # so a partial revert of the down-scope is caught.
    assert_not_contains "$region" 'fire at the **same `file:line`**' \
        "Step 6 precedence dedup: old file:line-keyed phrasing does not reappear"
}

# #470 finding #1 — the drop is guarded twice. Guard 1 restricts it to the
# operator-controlled AGNIX_CONFIG branch (under the TRUST=1 opt-in agnix reads
# the audited repo's OWN .agnix.toml, so a repo could delete floor coverage by
# shipping a config file). Guard 2 refuses to let a LOWER-severity agnix row
# supersede a higher-severity floor finding — the lowered-CC-HK-009 scenario.
test_step6_drop_guards() {
    local region
    region="$(extract_contract agnix-step6-precedence)"

    # Guard 1 — operator-config restriction.
    assert_wired "Step 6 guard 1" "$region" 'requires an operator-controlled agnix config'
    assert_contains "$region" 'CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1' \
        "Step 6 guard 1: names the trust opt-in whose branch loses the drop"
    assert_contains "$region" 'fall back to keep-both' \
        "Step 6 guard 1: keeps both findings under the trust opt-in"

    # Guard 2 — severity comparison. The severity must be read from the evidence
    # prefix, since certainty is now a fixed MEDIUM and is NOT a severity.
    assert_wired "Step 6 guard 2" "$region" 'never let a lower-severity agnix row'
    assert_contains "$region" 'rule_severity` from the `evidence` prefix' \
        "Step 6 guard 2: reads agnix severity from the evidence prefix"
    assert_contains "$region" 'empty/unparseable' \
        "Step 6 guard 2: keeps both when the severity cannot be compared"
    assert_contains "$region" 'is **not** a severity — never compare it' \
        "Step 6 guard 2: forbids comparing the fixed-MEDIUM certainty as a severity"
    # The two sides use different scales (agnix 3-tier UPPERCASE vs the schema's
    # 4-tier lowercase) — an unreconciled string compare is undefined behavior in
    # LLM-followed prose, so the ordinal and the case-fold must be stated.
    assert_contains "$region" 'case-fold before comparing' \
        "Step 6 guard 2: reconciles the two severity scales explicitly"
    assert_contains "$region" 'critical > high > medium > low' \
        "Step 6 guard 2: pins the ordinal used for the comparison"
    assert_contains "$region" 'never** superseded' \
        "Step 6 guard 2: a critical floor finding is never superseded (agnix has no critical tier)"
    # The severity parse must be ANCHORED at index 0 — the message half of
    # evidence is attacker-influenced and may embed a second bracket tag.
    assert_contains "$region" 'Anchor the parse at index 0' \
        "Step 6 guard 2: anchors the severity parse at the leading bracket group"
    assert_contains "$region" 'inert text' \
        "Step 6 guard 2: a later bracket group in the message is inert, not a severity source"
}

# #470 finding #2 (live residue) — an agnix row must be EXEMPT from the
# within-skill overlapping-line-range merge. Without the exemption a near-miss
# the precedence rule declined to drop (agnix @10 vs floor @12, or a guard unmet)
# falls through and gets BLENDED, re-opening by merge what #402 closed by key.
test_step6_within_skill_exemption() {
    local region
    region="$(extract_contract agnix-step6-precedence)"
    assert_wired "Step 6 merge exemption" "$region" 'exempt from this merge'
    assert_contains "$region" 'never blend' \
        "Step 6 merge exemption: forbids blending an agnix row into a floor finding"
    # The #402 per-issue key and this exemption must COMPOSE — the near-miss case
    # is the one that proves neither rule silently re-opens the other's gap.
    assert_contains "$region" 'agnix at line 10, the floor at line 12' \
        "Step 6 merge exemption: pins the near-miss case the two rules must compose on"
    assert_contains "$region" 'per underlying issue' \
        "Step 6 merge exemption: restates the #402 per-issue key it composes with"
    assert_contains "$region" 'overlapping line ranges' \
        "Step 6 merge exemption: names the merge key it is the boundary against"
}

# #470 finding #3 — Step 3a must state that certainty is a fixed MEDIUM and that
# agnix's rule_severity rides in the evidence prefix, so no agnix row reaches the
# report via the certainty=HIGH auto-include fast path without LLM confirmation.
test_step3a_certainty_tier() {
    local region
    region="$(agnix_prescan_region)"
    assert_wired "Step 3a certainty tier" "$region" 'fixed `MEDIUM`'
    assert_contains "$region" '[<RULE-ID>|<SEVERITY>] <message>' \
        "Step 3a certainty tier: pins the evidence prefix carrying the severity"
    assert_contains "$region" 'auto-include fast path' \
        "Step 3a certainty tier: names the fast path agnix rows must not take"
}

run_test test_step3a_invocation "Step 3a invokes agnix-normalize as a second pre-scan source"
run_test test_step3a_graceful_degrade "Step 3a skips agnix contribution when absent (graceful degrade)"
run_test test_step3a_trust "Step 3a enforces the operator-controlled AGNIX_CONFIG skip-gate"
run_test test_step3a_config_pinning "Step 3a always pins agnix to an explicit --config, never its own discovery (#471)"
run_test test_owned_category_parity "Step 3a and Step 6 agnix-owned category lists agree (#472)"
run_test test_observe_only_restriction "MUST-NOT list bans agnix autofix (observe-only, all 3 flags)"
run_test test_step6_precedence_dedup "Step 6 precedence-dedups agnix over check-ai-config (agnix-owned categories only)"
run_test test_step6_drop_guards "Step 6 guards the drop on operator config + agnix severity >= floor (#470)"
run_test test_step6_within_skill_exemption "Step 6 exempts agnix rows from the within-skill merge (#470)"
run_test test_step3a_certainty_tier "Step 3a pins the fixed-MEDIUM certainty tier + severity in evidence (#470)"

generate_report
