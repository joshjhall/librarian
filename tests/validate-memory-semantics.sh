#!/usr/bin/env bash
# audit-memory semantic-pass contract gate (issue #670, OKF slice C).
#
# Slice C is the one slice with NO deterministic runtime. Slices A and B ship a
# patterns.sh whose TSV output a fixture can diff byte-for-byte; slice C ships an
# AGENT, whose output is a judgment call made at inference time. So there is
# nothing here to run and compare — and that is precisely why the contract needs
# a gate rather than trusting review to re-read 392 lines of prose each time.
#
# WHAT THIS GATE CAN AND CANNOT DO. It pins the STRUCTURAL contract: the
# categories the agent declares, the config keys it reads, the redaction rule,
# the decline requirement, and the domain wiring that makes any of it reachable.
# It cannot verify that the LLM obeys them, exactly as
# tests/validate-audit-trust-gate.sh guards its prose and not the model's
# adherence. That residual is stated rather than papered over: the value here is
# catching DELETION and DRIFT — a category silently dropped from one of the three
# places it must appear, a convention quietly hardcoded past the config, the
# redaction sentence lost in an edit. Those are the failures this repo actually
# sees on hand-maintained prose contracts (#681, #830, #737).
#
# THE THREE-PLACE INVARIANT is the spine of the suite. Every semantic category
# must appear in all of:
#
#   1. the agent's Categories and Checklist section (how it is judged)
#   2. thresholds.yml severity_semantic (how it is ranked)
#   3. the agent's certainty table            (how sure it must be)
#
# A category in fewer than three is drift, in EITHER direction — an orphaned
# severity entry is as broken as an unranked category, so the checks below are
# bidirectional. Same shape and same reason as tests/lib/fragments.sh.
#
# NO HARDCODED CATEGORY LIST. The suite derives the category set from
# thresholds.yml and cross-checks the other two places against it. A hardcoded
# list here would be a FOURTH place to drift, which is the defect the gate exists
# to prevent (#663's rule, applied to a test).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

AGENT="$REPO_ROOT/plugins/review-audit/agents/audit-memory.md"
THRESHOLDS="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/thresholds.yml"
OKF_SKILL="$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/SKILL.md"
PROTOCOL="$REPO_ROOT/plugins/review-audit/skills/codebase-audit/orchestration-protocol.md"
TEMPLATES="$REPO_ROOT/plugins/review-audit/skills/codebase-audit/issue-templates.md"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "audit-memory semantic pass (#670)"

# --- Helpers ----------------------------------------------------------------

# semantic_categories — the category slugs under `severity_semantic:` in
# thresholds.yml, one per line. This is the SOURCE the rest of the suite keys
# off; every other place is checked against it, never against a literal list.
#
# Parsed by field index rather than by regex: a GNU-only shorthand class here
# would be a literal on BSD, and the parser would silently return nothing, leaving
# every downstream loop to iterate zero times and pass green (CLAUDE.md's
# GNU-only-regex rule, and the vacuity guard below is what catches it anyway).
semantic_categories() {
    command awk '
        /^severity_semantic:/ { in_block = 1; next }
        in_block && /^[^[:space:]#]/ { in_block = 0 }
        in_block {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            c = index(line, ":")
            if (c > 1) print substr(line, 1, c - 1)
        }
    ' "$THRESHOLDS"
}

# severity_for CAT — the severity value thresholds.yml ranks CAT at.
severity_for() {
    command awk -v want="$1" '
        /^severity_semantic:/ { in_block = 1; next }
        in_block && /^[^[:space:]#]/ { in_block = 0 }
        in_block {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            c = index(line, ":")
            if (c > 1 && substr(line, 1, c - 1) == want) {
                v = substr(line, c + 1)
                sub(/^[[:space:]]+/, "", v)
                sub(/[[:space:]]+$/, "", v)
                print v
            }
        }
    ' "$THRESHOLDS"
}

# agent_severity_for CAT — the severity the agent's own `### CAT` checklist
# subsection states, from its `- Severity: <level>.` line.
agent_severity_for() {
    command awk -v want="### $1" '
        $0 == want { c = 1; next }
        c && /^### / { c = 0 }
        c && /Severity:/ {
            line = $0
            i = index(line, "Severity:")
            v = substr(line, i + 9)
            sub(/^[[:space:]]+/, "", v)
            sub(/[^A-Za-z].*$/, "", v)
            print v
            exit
        }
    ' "$AGENT"
}

# agent_section NAME — the body of a `## NAME` section of the agent file, up to
# the next `## ` heading. Section scope (not whole-file) is what makes a
# placement assertion mean something: a token three screens away in an unrelated
# section satisfies a whole-file grep while telling the reader nothing.
agent_section() {
    command awk -v want="## $1" '
        $0 == want { capturing = 1; next }
        capturing && /^## / { capturing = 0 }
        capturing { print }
    ' "$AGENT"
}

# flatten — collapse all whitespace runs in stdin to single spaces, on one line.
#
# Every phrase assertion below runs through this, because a markdown phrase WRAPS:
# "never carry a memory's body" is stored as "...memory's\nbody" and a literal
# substring match against the raw section reports it missing while it is plainly
# there. That is the wrapped-line blindness this repo has hit before — a matcher
# that silently stops matching, in the direction that reads as a clean pass when
# inverted. Flattening first makes the assertion track the PROSE, not its
# line-breaking, so reflowing a paragraph cannot break the gate.
flatten() {
    command tr '\n' ' ' | command tr -s '[:space:]' ' '
}

# ============================================================================
# THE CATEGORY SET IS NON-EMPTY.
#
# The vacuity guard, and it runs FIRST. Every loop below iterates the parsed
# category set, so a parser that returns nothing turns this entire suite into a
# green no-op — the exact "0 files, silent gate" failure CLAUDE.md flags as
# dangerous because the scan still exits 0. Assert the count before trusting any
# check that consumes it.
# ============================================================================
test_category_set_is_parsed() {
    local cats count
    cats="$(semantic_categories)"
    count="$(command printf '%s\n' "$cats" | command grep -c . || true)"

    assert_not_empty "$cats" "severity_semantic parses to a non-empty category set"
    assert_true "[ '$count' -ge 5 ]" \
        "the semantic pass declares at least the 5 issue-mandated categories (got $count)"
    assert_contains "$cats" "memory-near-duplicate" \
        "the near-duplicate category — the slice's headline finding — is declared"
}

# ============================================================================
# THE THREE-PLACE INVARIANT, both directions.
#
# Bidirectional on purpose: a category the agent judges but nobody ranks is as
# broken as a severity entry nothing judges. A one-way check passes the day
# someone deletes a checklist section and leaves its severity row behind.
# ============================================================================
test_every_category_is_judged_and_graded() {
    local checklist certainty cat
    checklist="$(agent_section "Categories and Checklist")"
    certainty="$(agent_section "Certainty Assignment")"

    assert_not_empty "$checklist" "the agent has a Categories and Checklist section"
    assert_not_empty "$certainty" "the agent has a Certainty Assignment section"

    while IFS= read -r cat; do
        [ -n "$cat" ] || continue
        assert_contains "$checklist" "$cat" \
            "category '$cat' has a checklist entry saying how it is judged"
        assert_contains "$certainty" "$cat" \
            "category '$cat' has a certainty row saying how sure the agent must be"

        # PRESENCE IS NOT AGREEMENT. The three-place check above proves each
        # category is mentioned everywhere; it says nothing about the VALUES
        # agreeing. A future edit that bumps a category's severity in one place
        # and not the other passes every assertion above while the aggregator
        # ranks the finding differently from what the agent's own checklist
        # promises — precisely the drift this gate exists to catch, in the one
        # dimension it was previously blind to.
        local want got
        want="$(severity_for "$cat")"
        got="$(agent_severity_for "$cat")"
        assert_not_empty "$want" "category '$cat' has a severity value in thresholds.yml"
        assert_not_empty "$got" "category '$cat' states a Severity in its checklist entry"
        assert_equals "$want" "$got" \
            "category '$cat' is ranked the same in thresholds.yml and the agent checklist"
    done <<EOF
$(semantic_categories)
EOF
}

test_no_category_is_judged_without_a_grade() {
    # The reverse direction: every `memory-*` slug the checklist names must be a
    # declared category. Catches a section added to the agent that thresholds.yml
    # never learned about — which would emit findings the aggregator cannot rank.
    local declared checklist_cats cat
    declared="$(semantic_categories)"
    checklist_cats="$(agent_section "Categories and Checklist" |
        command awk '/^### memory-/ { print substr($0, 5) }')"

    assert_not_empty "$checklist_cats" \
        "the checklist section declares its categories as ### headings"

    while IFS= read -r cat; do
        [ -n "$cat" ] || continue
        assert_contains "$declared" "$cat" \
            "checklist category '$cat' is ranked in thresholds.yml severity_semantic"
    done <<EOF
$checklist_cats
EOF
}

# ============================================================================
# AC: "Duplicate findings carry the merged body AND the index-line deletion."
#
# Both halves, asserted in the near-duplicate section specifically. The merged
# body alone leaves a dangling index line pointing at a deleted file — which is
# `memory-dangling-index`, a finding slice B already emits. An auditor whose
# recommendation CREATES the defect its own sibling reports is worse than none.
# ============================================================================
test_duplicate_finding_carries_body_and_index_deletion() {
    local sect
    sect="$(agent_section "Categories and Checklist" |
        command awk '/^### memory-near-duplicate/ { c = 1; next } c && /^### / { c = 0 } c { print }' | flatten)"

    assert_not_empty "$sect" "the near-duplicate checklist section exists"
    assert_contains "$sect" "merged body" \
        "the duplicate finding must produce the merged body"
    assert_contains "$sect" "index line" \
        "the duplicate finding must name the index line to delete"
    assert_contains "$sect" "verbatim" \
        "the index line is quoted verbatim — a paraphrase is not actionable"
    assert_contains "$sect" "which file survives" \
        "the finding decides which file survives, leaving no choice to re-derive"
}

# ============================================================================
# AC: "No finding auto-applies; all recommendations are advisory."
#
# Checked at the TOOL level, not only in prose: an agent granted Edit or Write
# can apply a merge whatever its restrictions say, and #426 is this repo's
# standing evidence that a nominally read-only agent's prose does not bind its
# shell. The frontmatter is the enforceable half.
# ============================================================================
test_agent_cannot_apply() {
    local tools
    tools="$(command awk -F': ' '/^tools:/ { print $2; exit }' "$AGENT")"

    assert_not_empty "$tools" "the agent declares a tools list"
    assert_not_contains "$tools" "Edit" \
        "audit-memory holds no Edit — a merge must be human-confirmed, not applied"
    assert_not_contains "$tools" "Write" \
        "audit-memory holds no Write — the merged body is written by artifact-writer"
    assert_file_contains "$AGENT" "Recommend, do not apply" \
        "the agent states the advisory contract as a section of its own"

    # AND THE SAME MUST HOLD FOR WHAT IT DISPATCHES. The restrictions that make
    # this agent's Bash grant safe live in THIS file — a Task sub-agent never
    # receives them, so a batch worker inheriting a comparable toolset has no
    # prohibition against "helpfully" fixing a file it was asked to judge. The
    # control is withholding the tool, not repeating the prose.
    local batch
    batch="$(agent_section "Batch Sub-Agent Dispatching" | flatten)"
    assert_not_empty "$batch" "the agent documents how it batches"
    assert_contains "$batch" "\`Read\`, \`Grep\`, \`Glob\` only" \
        "batch sub-agents are dispatched with a narrowed toolset"
    assert_contains "$batch" "no \`Bash\`, \`Edit\`, \`Write\` or \`Task\`" \
        "the mutating tools are withheld from batch sub-agents by name"
}

# ============================================================================
# AC: "Never emits memory content into an issue body — artifact-writer path or
# redacted."
#
# The subtle half is the FALLBACK. An agent told "write the body to out_dir"
# meets an issue-objective run with out_dir empty, and the helpful thing to do —
# inline the body so the finding stays useful — is exactly the leak. So the
# contract must name the empty-out_dir case and forbid the inline fallback
# explicitly; a rule that only covers the happy path is not a rule.
# ============================================================================
test_redaction_contract_is_stated() {
    local redaction restrictions
    redaction="$(agent_section "Redaction — the hard rule" | flatten)"
    restrictions="$(agent_section "Restrictions" | flatten)"

    assert_not_empty "$redaction" "the agent carries an explicit redaction section"
    assert_contains "$redaction" "never carry a memory's body" \
        "redaction bans the body outright, not merely 'be careful'"
    assert_contains "$redaction" "80" \
        "redaction states the fragment cap in characters"
    assert_contains "$redaction" "out_dir" \
        "the merged body goes to the artifact-writer output directory"
    assert_contains "$redaction" "do **not** inline the body as a fallback" \
        "the empty-out_dir path is named and the inline fallback forbidden"
    # AND the permitted fallback is bounded. An unbounded "describe what the
    # merged body would say" re-admits as a PARAPHRASE exactly what the 80-char
    # cap excludes — on the one path that reaches an issue body, where the
    # audience is widest. A summary is an excerpt at lower resolution.
    assert_contains "$redaction" "never a paraphrase" \
        "the merge-plan fallback is bounded to shape, not a paraphrase of content"
    assert_contains "$restrictions" "issue body" \
        "the Restrictions section repeats the ban where a reader enforces it"
}

# ============================================================================
# AC: "Fixture pair of genuinely-distinct-but-similar memories the agent DECLINES
# to merge, with the reason recorded."
#
# The fixture is built to be one a merge-happy reading and a correct reading
# DISAGREE about: two memories sharing subject, vocabulary and shape, differing
# only in the TRIGGER. A pair that is obviously distinct would be declined by any
# reading at all and would prove nothing — the tautology this repo keeps
# rediscovering ("solve for the input where old and new differ").
#
# What the gate can assert deterministically is that the contract EQUIPS the
# agent to decline this pair: the trigger distinction is named as the operative
# test, and a decline is an emitted finding rather than a silence.
# ============================================================================
test_decline_is_a_finding_with_a_reason() {
    local decline dup a b
    decline="$(agent_section "The decline — say it out loud" | flatten)"

    assert_not_empty "$decline" "the agent carries an explicit decline section"
    assert_contains "$decline" "Emit the finding anyway" \
        "a decline is EMITTED — silence is indistinguishable from 'not examined'"
    assert_contains "$decline" "No action —" \
        "the decline suggestion has a fixed, greppable shape"
    assert_contains "$decline" "low" \
        "the decline uses severity low, which is in the finding-schema enum"
    assert_not_contains "$decline" "severity \`info\`" \
        "the decline does NOT use info, which has no defined rank in the aggregator"
    assert_contains "$decline" "Never silently drop" \
        "dropping a declined candidate is banned outright"

    # The decline must be REASONED, and the reason concrete enough to argue with.
    assert_contains "$decline" "concretely" \
        "the recorded reason must be concrete, not 'seems fine'"

    # The operative test that lets the fixture pair below be declined at all.
    dup="$(agent_section "Categories and Checklist" |
        command awk '/^### memory-near-duplicate/ { c = 1; next } c && /^### / { c = 0 } c { print }' | flatten)"
    assert_contains "$dup" "trigger" \
        "the same-lesson test is keyed on the TRIGGER — the distinction the fixture turns on"
    assert_contains "$dup" "Shared vocabulary is not enough" \
        "shared vocabulary is explicitly rejected as sufficient evidence of duplication"

    # The fixture pair itself: same subject, same shape, same nouns; different
    # triggering condition. Written to disk so the contract above is exercised
    # against a concrete artifact rather than asserted in the abstract.
    a="$WORKDIR/harness-budget-overrun.md"
    b="$WORKDIR/harness-judge-disagreement.md"
    command cat >"$a" <<'FIXTURE'
---
name: harness-budget-overrun
description: The review harness truncates its last dimension when the shared budget runs out
metadata:
  type: feedback
---

The review harness fans five dimensions out under one shared budget. When the
budget is exhausted mid-run, the last dimension returns truncated rather than
failing, so a green report can hide an unfinished dimension.

**Why:** a truncated dimension looks identical to a clean one in the summary.
**How to apply:** check the per-dimension token counts before trusting a cycle.
FIXTURE
    command cat >"$b" <<'FIXTURE'
---
name: harness-judge-disagreement
description: The review harness judge can rank a real defect deferrable when dimensions disagree
metadata:
  type: feedback
---

The review harness runs a fresh judge over the five dimensions' findings. When
two dimensions disagree about the same line, the judge's ordered rule list can
compute deferrable for a finding one dimension called blocking.

**Why:** the blocking bucket is what a reviewer reads; a real defect in the
deferrable bucket is one nobody looks at.
**How to apply:** read the deferrable bucket when two dimensions disagree.
FIXTURE

    assert_file_exists "$a" "fixture: the budget-overrun memory exists"
    assert_file_exists "$b" "fixture: the judge-disagreement memory exists"

    # The pair is genuinely similar: same subject, same type, same body shape.
    # Asserted so a future edit cannot weaken the fixture into an obviously
    # distinct pair that any reading would decline — which would make the case
    # pass for the wrong reason.
    assert_file_contains "$a" "review harness" "fixture: both memories share the subject"
    assert_file_contains "$b" "review harness" "fixture: both memories share the subject"
    assert_file_contains "$a" "shared budget" "fixture A's trigger is budget exhaustion"
    assert_file_contains "$b" "disagree" "fixture B's trigger is dimension disagreement"

    # And genuinely distinct: neither trigger appears in the other file. This is
    # the property that makes the pair a real test — if one trigger leaked into
    # both, the pair WOULD be a duplicate and declining it would be wrong.
    assert_file_not_contains "$a" "disagree" \
        "fixture: A does not carry B's trigger — the pair is genuinely distinct"
    assert_file_not_contains "$b" "shared budget" \
        "fixture: B does not carry A's trigger — the pair is genuinely distinct"
}

# ============================================================================
# AC: "Convention checks (naming, tiers) are config-driven, not
# librarian-hardcoded."
#
# Two halves, and the second is the one that actually bites. Declaring the config
# keys is easy; the failure mode is an agent that reads the config AND also names
# `.claude/memory` or `MEMORY.md` in a checklist, so a consuming repo with a
# different layout gets a wrong finding per file from the hardcoded half.
#
# The exemption is deliberate and narrow: `thresholds.yml` may name librarian's
# paths — that is what a DEFAULT is. The agent may not.
# ============================================================================
test_conventions_are_config_driven() {
    local checklist
    checklist="$(agent_section "Categories and Checklist")"

    # Every convention has a config key the agent is told to read.
    assert_file_contains "$AGENT" "config.tiers" \
        "tier placement is judged against configured tier roots"

    # The tier lists OVERLAP by construction (a long_term catch-all against a
    # short_term prefix), so `tmp/foo.md` matches both. Without a stated order
    # the tier of every short-term file is decided by whichever pattern the
    # reader tries first — an ambiguity a block arguing "config, not convention"
    # cannot leave in its own shipped defaults. Pinned in BOTH places a reader
    # might look: the config that ships the overlap, and the checklist entry
    # that makes the call.
    assert_contains "$(agent_section "Categories and Checklist" | flatten)" \
        "\`short_term\` first — the first list that matches wins" \
        "the checklist states which tier list wins when both match"
    assert_contains "$(command cat "$THRESHOLDS" | flatten)" \
        "\`short_term\` is checked FIRST" \
        "the config states the precedence it creates"
    assert_file_contains "$AGENT" "config.naming_policy" \
        "the naming judgment is switched by config, not assumed"
    assert_file_contains "$AGENT" "config.derivable_sources" \
        "derivable sources are configured, not a fixed list"
    assert_file_contains "$AGENT" "config.duplicate_sensitivity" \
        "merge confidence is operator-tunable"
    assert_file_contains "$AGENT" "config.health.index_names" \
        "which files route recall is read from the existing health block"
    assert_file_contains "$AGENT" "config.naming_exempt" \
        "the naming-policy exemptions are configured, not a fixed list"
    assert_file_contains "$AGENT" "health.body_requirements" \
        "per-type body requirements come from the existing health block"

    # The disabled-when-unconfigured rule. Without it, an unconfigured judgment
    # falls back to this repo's taste, which is the portability defect restated.
    assert_contains "$(agent_section "Everything here is configuration, not convention" | flatten)" \
        "is **disabled**, never defaulted" \
        "a judgment whose config is absent is disabled, not defaulted"

    # And the hardcode ban, checked where it would do damage.
    assert_not_contains "$checklist" ".claude/memory" \
        "no librarian bundle path is hardcoded in the checklist"
    assert_not_contains "$checklist" "MEMORY.md" \
        "no librarian index name is hardcoded in the checklist"

    # Every key the agent reads must actually exist in the table it reads from —
    # otherwise the agent is config-driven against configuration nobody wrote.
    assert_file_contains "$THRESHOLDS" "^semantic:" \
        "thresholds.yml carries the semantic block"
    assert_file_contains "$THRESHOLDS" "naming_policy:" "semantic.naming_policy is defined"
    assert_file_contains "$THRESHOLDS" "duplicate_sensitivity:" \
        "semantic.duplicate_sensitivity is defined"
    assert_file_contains "$THRESHOLDS" "derivable_sources:" \
        "semantic.derivable_sources is defined"
    assert_file_contains "$THRESHOLDS" "naming_exempt:" "semantic.naming_exempt is defined"
    assert_file_contains "$THRESHOLDS" "body_requirements:" "health.body_requirements is defined"
    assert_file_contains "$THRESHOLDS" "long_term:" "semantic.tiers.long_term is defined"
    assert_file_contains "$THRESHOLDS" "short_term:" "semantic.tiers.short_term is defined"
}

# ============================================================================
# THE DELEGATION HOLDS.
#
# Slice B pinned index SIZING to check-decomposition rather than defining a second
# threshold table (#663). Slice C is the obvious place for that delegation to
# decay — index-line QUALITY is genuinely its business, and "while I'm here"
# index length is one sentence away. Pin the boundary now, on the same reasoning
# the slice-B test does.
# ============================================================================
test_index_sizing_stays_delegated() {
    assert_file_contains "$AGENT" "check-decomposition" \
        "the agent names the owner of index budgets"
    assert_contains "$(agent_section "Guidelines" | flatten)" \
        "Do not judge index **size**" \
        "the agent is told not to judge index size"
    assert_file_not_contains "$AGENT" "index_budget" \
        "the agent defines no index budget of its own"
    assert_file_not_contains "$THRESHOLDS" "memory_index:" \
        "thresholds.yml still defines no index budget (slice B's delegation holds)"
}

# ============================================================================
# THE DOMAIN IS REACHABLE.
#
# Everything above describes an agent nothing dispatches unless the wiring
# exists. Three places make it reachable, and an audit run silently omits the
# whole slice if any one is missing — no error, just a domain that never appears
# in `domains[]`. That is the discovery failure mode CLAUDE.md warns about for
# flat agents, restated at the routing layer.
# ============================================================================
test_memory_domain_is_wired() {
    # Flattened, because both facts live in wrapped prose. An assertion anchored
    # to a LINE BREAK is a contract anchored to formatting: reflowing the
    # paragraph — which dprint may do on any future edit — would fail the gate
    # while the guarantee is untouched, and the fix would be to un-reflow the
    # prose to satisfy the test. Match the sentence, not its line-breaking.
    # Scoped to the two sections that carry the facts, and FLATTENED. Two
    # reasons, both learned the hard way in this repo:
    #
    # (1) Flattened, because an assertion anchored to a LINE BREAK is a contract
    #     anchored to formatting. Reflowing the paragraph — which a future edit
    #     or dprint may do — would fail the gate while the guarantee is
    #     untouched, and the only way to go green would be to un-reflow prose to
    #     satisfy a test. Match the sentence, not its line-breaking.
    # (2) Scoped, because a whole-file haystack makes a failure unreadable: the
    #     harness prints the haystack, and a 315-line file flattened to one line
    #     buries the missing needle in 20 KB of unrelated prose. A section-scoped
    #     region also means the fact must be where a reader will be.
    local map_region domain_region routing_region
    map_region="$(command awk '/Map findings to scanner domains/ { c = 1 } c && /Include pre-scan findings/ { c = 0 } c { print }' "$PROTOCOL" | flatten)"
    domain_region="$(command awk '/^The active scanner set is whatever/ { c = 1 } c && /^The \*\*verify\*\* pass/ { c = 0 } c { print }' "$PROTOCOL" | flatten)"
    routing_region="$(command awk '/^[|] File Type/ { c = 1 } c && /^Build a manifest object/ { c = 0 } c { print }' "$PROTOCOL" | flatten)"

    assert_contains "$map_region" '`check-okf-conformance` → `audit-memory`' \
        "the scanner->domain map routes check-okf-conformance rows to audit-memory"
    assert_contains "$domain_region" "lifecycle, memory; plus" \
        "memory is in the built-in domain list"
    assert_contains "$routing_region" "Memory bundle files" \
        "memory-bundle files are routed in the Step 2 table"

    # THE ROUTING ROW IS KEYED ON A STEP 1 LABEL, so a row naming a label Step 1
    # never produces routes NOTHING. That was a live defect in this very change:
    # the Step 2 row shipped before the Step 1 classification existed, so a
    # bundle file classified as Doc or AI Config, the memory domain got an empty
    # file list, and the slice would have reported a clean bundle it never read —
    # a silent gap, the worst shape of wrong. Assert BOTH halves and the
    # precedence that connects them.
    local class_region
    class_region="$(command awk '/^[|] Classification/ { c = 1 } c && /^4[.] Filter untracked/ { c = 0 } c { print }' "$PROTOCOL" | flatten)"

    assert_contains "$class_region" "Memory bundle" \
        "Step 1 CLASSIFIES memory-bundle files — the label Step 2 routes on"
    assert_contains "$class_region" "OKF_BUNDLE_ROOT" \
        "the classification keys off the resolved bundle root, not a hardcoded path"
    assert_contains "$class_region" "takes precedence over AI Config and Doc" \
        "precedence is stated — a bundle file matches all three patterns"
    assert_file_contains "$TEMPLATES" 'audit/memory' \
        "the audit/memory category label is declared"
    assert_file_contains "$OKF_SKILL" "audit-memory" \
        "the scanner's Pass 2 section names its semantic consumer"

    # THE PROSE TABLE IS NOT THE ONLY CONSUMER. orchestration-protocol.md is
    # documentation; the two things that actually run are checker.md (which
    # classifies) and the GENERATED codebase-audit workflow.js (whose mapPrompt
    # string is the literal instruction the map agent receives). A classification
    # added to the doc alone leaves the domain dead in production while every
    # doc-only assertion passes — which is exactly how this shipped in review
    # cycle 2. Assert all three, and assert the GENERATED artifact, not just its
    # fragment: the artifact is what installs.
    local checker_md map_js
    checker_md="$REPO_ROOT/plugins/review-audit/agents/checker.md"
    map_js="$REPO_ROOT/plugins/review-audit/skills/codebase-audit/workflow.js"

    assert_contains "$(command cat "$checker_md" | flatten)" "memory bundle" \
        "checker.md Step 1 classifies memory-bundle files"
    # The bare mention is not enough. A consumer that names the label but drops
    # the precedence clause classifies bundle files as Doc/AI Config again — a
    # milder rerun of the cycle-2 dead-wiring bug, and one a "does it mention
    # memory bundle" check passes straight through.
    #
    # SCOPED TO STEP 1, and that is load-bearing: checker.md says "precedence
    # rule" twice, the second time about agnix precedence three screens away.
    # A whole-file match therefore passed with the real clause DELETED — caught
    # by mutating it, which is the only thing that distinguishes an assertion
    # with teeth from one that merely looks right.
    local checker_step1
    checker_step1="$(command awk '/^### Step 1: Parse Scope/ { c = 1; next } c && /^### / { c = 0 } c { print }' "$checker_md" | flatten)"
    assert_not_empty "$checker_step1" "checker.md has a Step 1 section"
    assert_contains "$checker_step1" "precedence rule" \
        "checker.md Step 1 carries the precedence rule, not just the label"
    assert_file_contains "$map_js" "memory-bundle->memory" \
        "the generated map prompt routes memory-bundle files to the memory domain"
    assert_file_contains "$map_js" "memory-bundle; a .md under" \
        "the generated map prompt tells the agent how to classify one"

    # AND THE THREE MUST AGREE ON PRECEDENCE, not merely each mention it.
    # Precedence is now stated in three places; three copies that may diverge is
    # the same duplication risk the one-threshold-table rule exists to prevent.
    # A consumer that ranked doc/ai-config first would classify bundle files
    # away from the memory domain while still "mentioning precedence" — so
    # assert the ORDER each one states, not the word.
    assert_contains "$(command cat "$PROTOCOL" | flatten)" \
        "takes precedence over AI Config and Doc" \
        "the protocol ranks memory-bundle ABOVE ai-config and doc"
    # NOTE: match a fragment that lives inside ONE string literal. The full
    # sentence straddles a `+` concat boundary in the generated artifact, and
    # flattening collapses whitespace, not JS operators — a phrase spanning the
    # boundary never matches no matter how the file is normalized.
    assert_contains "$(command cat "$map_js" | flatten)" \
        "the broader ai-config and doc patterns" \
        "the generated map prompt ranks it the same way (memory-bundle above ai-config/doc)"
}

# ============================================================================
# THE AGENT IS DISCOVERABLE AS A FLAT FILE.
#
# CLAUDE.md's packaging rule: a nested agents/<name>/<name>.md is SILENTLY not
# discovered. lint-skills-agents.sh enforces the layout globally; this asserts it
# for this agent specifically, so a future move of the file fails here with a
# message naming the rule rather than in a global sweep.
# ============================================================================
test_agent_is_flat_and_named() {
    local name
    assert_file_exists "$AGENT" "the agent is a flat agents/audit-memory.md"
    assert_true "[ ! -d '$REPO_ROOT/plugins/review-audit/agents/audit-memory' ]" \
        "no nested agents/audit-memory/ dir — nested agents are silently undiscovered"

    name="$(command awk -F': ' '/^name:/ { print $2; exit }' "$AGENT")"
    assert_equals "audit-memory" "$name" \
        "frontmatter name matches the filename (discovery keys on it)"
}

# ============================================================================
# THE ACKNOWLEDGMENT CONTRACT.
#
# Every other load-bearing section here has a test; this one had none. Its two
# non-obvious rules are exactly the kind a later edit drops silently: an ack on
# EITHER file of a duplicate pair suppresses the pair (an ack on one file only
# would leave the pair re-reported from the other direction forever), and a
# stale ack RE-RAISES rather than suppressing forever — the property that stops
# an acknowledgment becoming a permanent blindfold.
# ============================================================================
test_acknowledgment_contract_is_stated() {
    local ack
    ack="$(agent_section "Inline Acknowledgment Handling" | flatten)"

    assert_not_empty "$ack" "the agent carries an acknowledgment section"
    assert_contains "$ack" "audit:acknowledge category=" \
        "the acknowledgment comment syntax is stated verbatim"
    assert_contains "$ack" "on **either** file of the pair" \
        "an ack on either file suppresses a duplicate pair"
    assert_contains "$ack" "older than 12 months" \
        "a stale acknowledgment expires rather than suppressing forever"
    assert_contains "$ack" "re-raise" \
        "an expired acknowledgment RE-RAISES — an ack is not a permanent blindfold"
    assert_contains "$ack" "acknowledged_findings" \
        "suppressed findings are recorded, not dropped"
}

run_test test_category_set_is_parsed "categories: severity_semantic parses non-empty (vacuity guard)"
run_test test_every_category_is_judged_and_graded "categories: each is judged AND graded"
run_test test_no_category_is_judged_without_a_grade "categories: none is judged without a grade"
run_test test_duplicate_finding_carries_body_and_index_deletion "duplicate: merged body AND index-line deletion"
run_test test_agent_cannot_apply "advisory: no Edit/Write — merges are human-confirmed"
run_test test_redaction_contract_is_stated "redaction: no bodies, and no inline fallback when out_dir is empty"
run_test test_decline_is_a_finding_with_a_reason "decline: an emitted finding with a concrete reason, on a distinct-but-similar pair"
run_test test_conventions_are_config_driven "portability: conventions are config, and nothing is hardcoded"
run_test test_index_sizing_stays_delegated "delegation: index sizing stays with check-decomposition"
run_test test_memory_domain_is_wired "wiring: the memory domain is reachable from an audit run"
# ============================================================================
# THE AGENT IS DOCUMENTED WHERE READERS COUNT AGENTS.
#
# Both READMEs carry a COUNT, and a count is a claim that goes stale silently:
# on main the plugin table said "9 skills · 9 agents" against a real 12 and 10,
# and the plugin README's agent table was missing `audit-decomposition` (added
# in #674, never listed). Nothing noticed, because nothing checked. Derive the
# truth from the filesystem and compare — a hardcoded expected number here would
# be a third copy to drift.
# ============================================================================
test_agent_is_documented() {
    local n_agents n_skills plugin_readme root_readme
    plugin_readme="$REPO_ROOT/plugins/review-audit/README.md"
    root_readme="$REPO_ROOT/README.md"
    n_agents="$(command ls "$REPO_ROOT/plugins/review-audit/agents"/*.md | command wc -l | command tr -d ' ')"
    n_skills="$(command ls -d "$REPO_ROOT/plugins/review-audit/skills"/*/ | command wc -l | command tr -d ' ')"

    assert_file_contains "$plugin_readme" "^## Agents ($n_agents)\$" \
        "the plugin README's agent count matches the tree ($n_agents)"
    assert_file_contains "$plugin_readme" 'audit-memory' \
        "audit-memory has a row in the plugin README's agent table"
    assert_file_contains "$root_readme" "$n_skills skills · $n_agents agents" \
        "the root README's review-audit row matches the tree"
}

run_test test_agent_is_documented "docs: both READMEs count agents correctly and list audit-memory"
run_test test_acknowledgment_contract_is_stated "acknowledgment: either-file pair suppression + 12-month expiry"
run_test test_agent_is_flat_and_named "packaging: flat agents/audit-memory.md with a matching name"

generate_report
