#!/usr/bin/env bash
# codebase-audit project-source integrity-gate contract (issues #124, #125).
#
# PR #122 (issue #107) added the `CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1`
# supply-chain opt-in that gates every project-supplied surface the audit
# pipeline can reach. That gate is LLM-followed PROSE, not executable shell —
# the `checker` agent and the codebase-audit orchestrator read it and act on it.
# There is no runtime to unit-test, so this is a PROSE-CONTRACT / drift gate in
# the style of tests/validate-template-sync.sh and
# tests/validate-shared-scanner-sync.sh: it pins that each surface still carries
# the opt-in, its exact-value-`1` semantics, and its surface-specific skip log
# line, so the invariant cannot silently drift out of one file.
#
# Six surfaces across two files, one trust boundary:
#
#   checker.md   Step 2 — project check-* skill discovery  → [discovery] skipped project skill
#   checker.md   Step 2 — project audit-* agent discovery   → [map] skipped project agent   (#124-A)
#   checker.md   Step 3 — project patterns.sh execution     → [prescan] skipped
#   checker.md   Backward-Compat — audit-* dispatch          → [map] skipped project agent   (#124-B)
#   protocol.md  Step 1.8 — project audit-* agent gate       → [map] skipped project agent
#   protocol.md  Step 2.5 — project patterns.sh prescan gate → [prescan] skipped
#
# Each surface gets: a live assertion (the region carries the env var, the
# exact-value semantics, and its log line) plus a tamper guard (stripping the
# env-var lines removes the gate token and demonstrably changes the region), so
# the live assertion can never pass against an empty / wrongly-anchored extract.
#
# Pure bash + coreutils; no node/jq. Full /usr/bin/* paths per project shell
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

CHECKER="$REPO_ROOT/plugins/review-audit/agents/checker.md"
PROTOCOL="$REPO_ROOT/plugins/review-audit/skills/codebase-audit/orchestration-protocol.md"
ENV_VAR="CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS"

test_suite "audit project-source integrity gate (#124/#125)"

# Contract blocks are addressed BY ID, resolved anywhere under plugins/, so this
# gate no longer names the file a surface lives in.
# shellcheck disable=SC2034  # read by extract_contract in the sourced harness
CONTRACT_SEARCH_ROOT="$REPO_ROOT/plugins"

# WHY IDS, NOT ANCHOR PAIRS. Each surface used to be extracted between two
# literal strings — a heading, or worse an English sentence
# (`'Integrity gate — branch on'` .. `'Integrity gate for project-level'`). Every
# such pair is a hidden coupling: rewording a sentence that happens to be some
# other test's sentinel silently re-anchors that test, and moving a section
# breaks assertions whose guarantee never changed. Surface 3 depended on
# `'#### Step 3a:'` — a heading belonging to an unrelated sub-step, which #503
# then moved — so a prose extraction elsewhere would have silently expanded this
# region to swallow it.
#
# extract_contract (tests/lib/harness.sh) addresses a block by an id embedded in
# the prose. It fails LOUD on a missing or duplicated id rather than returning an
# empty region every assert_contains would then pass against. See that helper for
# the full rationale; the local extract_between copy this file used to carry is
# gone in favour of the shared one.

# assert_surface LABEL REGION LOGLINE — one gated surface carries the whole
# contract: the opt-in env var, its exact-value-`1` semantics, and the
# surface-specific skip log line. The tamper guard (strip the env-var lines)
# proves the region is real and non-empty, so none of the live asserts pass
# vacuously against a wrongly-anchored / empty extract.
assert_surface() {
    local label="$1" region="$2" logline="$3"

    assert_not_empty "$region" "$label: region extracted (section anchors intact)"

    # The <=60-line single-section bound that used to sit here is gone. It
    # existed to catch an anchor that had matched the wrong place and run past
    # its END sentinel — a failure an id-delimited region cannot have, since it
    # ends at the next contract marker or EOF by construction. Keeping it would
    # have meant a prose budget masquerading as a correctness check: a gated
    # section that legitimately grew past 60 lines would fail a test that never
    # had anything to say about length.

    assert_contains "$region" "$ENV_VAR" "$label: carries the $ENV_VAR opt-in"
    assert_contains "$region" "$logline" "$label: logs '$logline' on skip"

    # Exact-value-`1` semantics: collapse all whitespace (incl. newlines) to
    # single spaces first — several surfaces wrap "exact value `1`" across a line
    # break, so a raw substring match would miss them.
    local flat
    flat="$(printf '%s' "$region" | command tr -s '[:space:]' ' ')"
    assert_contains "$flat" "exact value" "$label: documents exact-value-1 opt-in semantics"

    # Tamper: dropping every env-var line must remove the gate token AND change
    # the region. Comparison is plain bash (NOT assert_true, which eval's its
    # argument — the region holds shell metacharacters that eval would execute).
    local tampered changed="no"
    tampered="$(printf '%s\n' "$region" | command grep -vF "$ENV_VAR" || true)"
    [ "$region" != "$tampered" ] && changed="yes"
    assert_not_contains "$tampered" "$ENV_VAR" \
        "$label: stripping the gate line removes the opt-in token (extract targets the real region)"
    assert_equals "yes" "$changed" \
        "$label: the gate line is genuinely present (tamper changed the region)"
}

# Surface 1 — checker.md Step 2: project check-* skill discovery gate.
test_checker_skill_discovery_gate() {
    assert_file_exists "$CHECKER" "checker.md exists"
    local region
    region="$(extract_contract checker-skill-discovery-gate)"
    assert_surface "checker Step 2 skill discovery" \
        "$region" '[discovery] skipped project skill'
}

# Surface 2 — checker.md Step 2: project audit-* AGENT discovery gate (#124-A).
test_checker_agent_discovery_gate() {
    local region
    region="$(extract_contract checker-agent-discovery-gate)"
    assert_surface "checker Step 2 agent discovery" \
        "$region" '[map] skipped project agent'
}

# Surface 3 — checker.md Step 3: project patterns.sh execution gate.
# Previously ended at the `#### Step 3a:` heading — a borrowed sentinel owned by
# an unrelated sub-step, which #503 then moved to a companion file. The contract
# id ends the region on its own terms, so that coupling is gone.
test_checker_prescan_gate() {
    local region
    region="$(extract_contract checker-prescan-gate)"
    assert_surface "checker Step 3 prescan" "$region" '[prescan] skipped'
}

# Surface 4 — checker.md Backward-Compat: audit-* dispatch gate (#124-B).
test_checker_backcompat_dispatch_gate() {
    local region
    region="$(extract_contract checker-backcompat-dispatch)"
    assert_surface "checker Backward-Compat dispatch" \
        "$region" '[map] skipped project agent'
}

# Surface 5 — orchestration-protocol.md Step 1.8: project audit-* agent gate.
test_protocol_agent_gate() {
    assert_file_exists "$PROTOCOL" "orchestration-protocol.md exists"
    local region
    region="$(extract_contract protocol-agent-gate)"
    assert_surface "protocol Step 1.8 agent gate" \
        "$region" '[map] skipped project agent'
}

# Surface 6 — orchestration-protocol.md Step 2.5: project patterns.sh prescan gate.
test_protocol_prescan_gate() {
    local region
    region="$(extract_contract protocol-prescan-gate)"
    assert_surface "protocol Step 2.5 prescan gate" "$region" '[prescan] skipped'
}

# Surface 7 — checker.md Step 2 source-classification contract. The trust gate's
# skip/allow decision hinges on an audit-* agent being classified `project`
# (repo `.claude/agents/...`) vs `legacy` (`~/.claude/agents/...`); if that
# discovery-glob + classification prose is removed or the labels are swapped,
# the gate surfaces above still read fine but the input feeding them is wrong.
# Pin the classification the same way (this region precedes every gate anchor,
# so it is not covered by surfaces 1-6).
test_checker_source_classification() {
    # Span the precedence-list item (which names the discovery glob) through the
    # `source:` classification note, up to the first gate anchor.
    local region
    region="$(extract_contract checker-source-classification)"
    assert_not_empty "$region" "source classification: region extracted (anchors intact)"
    assert_contains "$region" '.claude/agents/audit-' \
        "source classification: names the project-level audit-* discovery glob"
    assert_contains "$region" 'project` when found under' \
        "source classification: classifies repo .claude/agents as project"
    assert_contains "$region" 'legacy` when found under' \
        "source classification: classifies ~/.claude/agents as legacy"
}

run_test test_checker_skill_discovery_gate "checker Step 2 gates project check-* skill discovery"
run_test test_checker_agent_discovery_gate "checker Step 2 gates project audit-* agent discovery (#124-A)"
run_test test_checker_prescan_gate "checker Step 3 gates project patterns.sh execution"
run_test test_checker_backcompat_dispatch_gate "checker Backward-Compat gates audit-* dispatch (#124-B)"
run_test test_protocol_agent_gate "orchestration Step 1.8 gates project audit-* agents"
run_test test_protocol_prescan_gate "orchestration Step 2.5 gates project patterns.sh prescan"
run_test test_checker_source_classification "checker Step 2 pins project/legacy source classification (#124-A)"

generate_report
