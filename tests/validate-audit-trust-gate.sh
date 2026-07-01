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

# extract_between FILE START END — the lines strictly between the first line
# containing the fixed string START and the next line containing END (both
# sentinel lines excluded). Fixed-string index() matching, so backtick/`\*`/em-dash
# in the surrounding headings need no escaping.
#
# The END sentinel is REQUIRED: if it is never found (e.g. a heading was
# renamed), the buffered region is discarded and nothing is printed, rather than
# silently expanding to EOF. Without this, a renamed downstream heading would
# grow the region to the rest of the file, and the env-var/log-line assertions
# could pass on unrelated later sections while the gate prose was actually gone.
extract_between() {
    /usr/bin/awk -v s="$2" -v e="$3" '
        index($0, s) { grab = 1; next }
        grab && index($0, e) { closed = 1; exit }
        grab { buf = buf $0 "\n" }
        END { if (closed) printf "%s", buf }
    ' "$1"
}

# assert_surface LABEL REGION LOGLINE — one gated surface carries the whole
# contract: the opt-in env var, its exact-value-`1` semantics, and the
# surface-specific skip log line. The tamper guard (strip the env-var lines)
# proves the region is real and non-empty, so none of the live asserts pass
# vacuously against a wrongly-anchored / empty extract.
assert_surface() {
    local label="$1" region="$2" logline="$3"

    assert_not_empty "$region" "$label: region extracted (section anchors intact)"

    # Upper-bound the region size. Any single gated section is well under 60
    # lines; a much larger region means an anchor matched the wrong place (or,
    # defensively, an EOF-expansion that slipped past extract_between's END
    # guard). Catch it here rather than letting the assertions below pass on a
    # bloated region that happens to contain the tokens somewhere.
    local line_count
    line_count="$(printf '%s\n' "$region" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    assert_true "[ \"$line_count\" -le 60 ]" \
        "$label: extracted region is a single section ($line_count lines, expected <= 60)"

    assert_contains "$region" "$ENV_VAR" "$label: carries the $ENV_VAR opt-in"
    assert_contains "$region" "$logline" "$label: logs '$logline' on skip"

    # Exact-value-`1` semantics: collapse all whitespace (incl. newlines) to
    # single spaces first — several surfaces wrap "exact value `1`" across a line
    # break, so a raw substring match would miss them.
    local flat
    flat="$(printf '%s' "$region" | /usr/bin/tr -s '[:space:]' ' ')"
    assert_contains "$flat" "exact value" "$label: documents exact-value-1 opt-in semantics"

    # Tamper: dropping every env-var line must remove the gate token AND change
    # the region. Comparison is plain bash (NOT assert_true, which eval's its
    # argument — the region holds shell metacharacters that eval would execute).
    local tampered changed="no"
    tampered="$(printf '%s\n' "$region" | /usr/bin/grep -vF "$ENV_VAR" || true)"
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
    region="$(extract_between "$CHECKER" \
        'Integrity gate — branch on' 'Integrity gate for project-level')"
    assert_surface "checker Step 2 skill discovery" \
        "$region" '[discovery] skipped project skill'
}

# Surface 2 — checker.md Step 2: project audit-* AGENT discovery gate (#124-A).
test_checker_agent_discovery_gate() {
    local region
    region="$(extract_between "$CHECKER" \
        'Integrity gate for project-level' 'Domain override rule')"
    assert_surface "checker Step 2 agent discovery" \
        "$region" '[map] skipped project agent'
}

# Surface 3 — checker.md Step 3: project patterns.sh execution gate.
test_checker_prescan_gate() {
    local region
    region="$(extract_between "$CHECKER" '### Step 3:' '### Step 4:')"
    assert_surface "checker Step 3 prescan" "$region" '[prescan] skipped'
}

# Surface 4 — checker.md Backward-Compat: audit-* dispatch gate (#124-B).
test_checker_backcompat_dispatch_gate() {
    local region
    region="$(extract_between "$CHECKER" \
        '## Backward Compatibility' '## Error Handling')"
    assert_surface "checker Backward-Compat dispatch" \
        "$region" '[map] skipped project agent'
}

# Surface 5 — orchestration-protocol.md Step 1.8: project audit-* agent gate.
# Anchored to the gate paragraph itself (not the whole ## Step span) so the
# region is the single gated section the <=60-line guard expects.
test_protocol_agent_gate() {
    assert_file_exists "$PROTOCOL" "orchestration-protocol.md exists"
    local region
    region="$(extract_between "$PROTOCOL" \
        'Integrity gate (same trust boundary' 'Gate project-level check-')"
    assert_surface "protocol Step 1.8 agent gate" \
        "$region" '[map] skipped project agent'
}

# Surface 6 — orchestration-protocol.md Step 2.5: project patterns.sh prescan gate.
# Anchored to the "For each patterns.sh" gate item through the "passes the gate"
# line that closes it, for the same single-section reason as surface 5.
test_protocol_prescan_gate() {
    local region
    region="$(extract_between "$PROTOCOL" \
        'For each patterns.sh found' 'for a script that passes the gate')"
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
    region="$(extract_between "$CHECKER" \
        'Backward-compatible audit agents' 'Integrity gate — branch on')"
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
