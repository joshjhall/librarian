#!/usr/bin/env bash
# Cross-reference integrity gate for SKILL.md agent references (issue #41).
#
# A SKILL.md can name an agent in its frontmatter via `subagent_type:`. If that
# agent is renamed, removed, or never created, the skill silently ships with a
# dangling reference — no compiler catches it. This gate collects every
# subagent_type value declared in SKILL.md frontmatter across all three plugins
# and verifies each resolves to a real flat agent file at
# plugins/*/agents/<name>.md, failing with a clear list of dangling references.
#
# The general agent-name resolver lives in tests/lib/agent-resolver.sh so the
# companion workflow.js `agentType` check (issue #40) can reuse it.
#
# Pure bash + coreutils; no node/jq. Empty plugins pass (no SKILL.md references
# to resolve). A committed negative fixture proves the detector fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=tests/lib/agent-resolver.sh
source "$SCRIPT_DIR/lib/agent-resolver.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/crossref"

test_suite "SKILL.md ↔ Agent Cross-Reference Integrity"

# Every subagent_type referenced by a real SKILL.md resolves to an agent file.
test_skill_subagent_types_resolve() {
    local dangling="" line skill name
    while IFS=$'\t' read -r skill name; do
        [ -n "$name" ] || continue
        if ! agent_resolver_exists "$PLUGINS_DIR" "$name"; then
            dangling="${dangling}${skill}: subagent_type '${name}' -> no plugins/*/agents/${name}.md"$'\n'
        fi
    done < <(collect_skill_subagent_types "$PLUGINS_DIR")

    if [ -n "$dangling" ]; then
        local detail=()
        while IFS= read -r line; do
            [ -n "$line" ] && detail+=("$line")
        done <<<"$dangling"
        _fail "Dangling subagent_type reference(s) in SKILL.md frontmatter" "${detail[@]}"
    fi
}

# The detector FIRES on a known-bad fixture: a SKILL.md whose subagent_type
# names a nonexistent agent must be reported. Without this the live sweep only
# ever proves the happy path (and would pass vacuously today, as no real
# SKILL.md yet declares subagent_type).
test_crossref_detector_fires_on_fixture() {
    local fixture="$FIXTURES_DIR/skill_subagent_dangling.md"
    assert_file_exists "$fixture" "Negative cross-ref fixture exists"
    [ -f "$fixture" ] || return 0

    # The fixture references this agent; assert it does NOT resolve.
    local bad_name="this-agent-does-not-exist"
    if agent_resolver_exists "$PLUGINS_DIR" "$bad_name"; then
        assert_true false \
            "Fixture agent '$bad_name' unexpectedly resolves — fixture is no longer dangling"
        return 0
    fi

    # Drive the collector over a throwaway plugins tree containing the fixture as
    # a SKILL.md, and assert the collector surfaces the dangling name.
    local tmp
    tmp="$(command mktemp -d)"
    command mkdir -p "$tmp/p/skills/dangling-fixture"
    command cp "$fixture" "$tmp/p/skills/dangling-fixture/SKILL.md"

    local collected
    collected="$(collect_skill_subagent_types "$tmp")"
    command rm -rf "$tmp"

    assert_contains "$collected" "$bad_name" \
        "Collector extracts subagent_type '$bad_name' from the fixture frontmatter"
}

# The detector fires end-to-end for the multi-value YAML shapes — the inline-flow
# list `[a, b]` and the multi-entry block list. The scalar fixture above only
# exercises one name in one shape, so a parser regression that silently dropped a
# list element (or handled only the first) would slip through without these. Each
# fixture names two nonexistent agents; for each shape we assert (1) the collector
# surfaces BOTH names and (2) the full gate (collect -> agent_resolver_exists)
# flags BOTH as dangling — not just the collector in isolation.
test_crossref_detector_fires_on_list_fixtures() {
    local both_names=("this-agent-does-not-exist" "another-missing-agent")
    local fixture name path tmp collected dangling

    # The fixtures are only meaningful while their agent names stay unresolved.
    # Guard the invariant so a real agent created by one of these names produces
    # a clear failure here instead of silently defanging the fixtures.
    for name in "${both_names[@]}"; do
        if agent_resolver_exists "$PLUGINS_DIR" "$name"; then
            assert_true false \
                "Fixture agent '$name' unexpectedly resolves — list fixture is no longer dangling"
            return 0
        fi
    done

    for fixture in skill_subagent_inline_list skill_subagent_block_list; do
        path="$FIXTURES_DIR/${fixture}.md"
        assert_file_exists "$path" "List cross-ref fixture exists ($fixture)"
        [ -f "$path" ] || continue

        # Drive the gate over a throwaway plugins tree holding the fixture as a
        # SKILL.md. The trap guarantees cleanup even if a command below exits
        # non-zero under `set -euo pipefail`, so no temp dir leaks on failure.
        tmp="$(command mktemp -d)"
        # shellcheck disable=SC2064  # expand $tmp now, not at trap time
        trap "command rm -rf '$tmp'" RETURN
        command mkdir -p "$tmp/p/skills/$fixture"
        command cp "$path" "$tmp/p/skills/$fixture/SKILL.md"

        collected="$(collect_skill_subagent_types "$tmp")"

        # Re-run the resolver step the live gate uses, collecting dangling names.
        dangling=""
        while IFS=$'\t' read -r _ name; do
            [ -n "$name" ] || continue
            agent_resolver_exists "$tmp" "$name" || dangling="${dangling}${name}"$'\n'
        done <<<"$collected"

        for name in "${both_names[@]}"; do
            assert_contains "$collected" "$name" \
                "Collector extracts '$name' from $fixture frontmatter"
            assert_contains "$dangling" "$name" \
                "Gate flags '$name' from $fixture as dangling"
        done

        command rm -rf "$tmp"
        trap - RETURN
    done
}

# A positive control: a known real agent name resolves through the resolver.
# Guards against the resolver returning false for everything (which would make
# the gate pass vacuously).
test_resolver_finds_a_real_agent() {
    local first
    first="$(agent_resolver_index "$PLUGINS_DIR" | command head -1)"
    [ -n "$first" ] || {
        skip_test "no agents found in tree"
        return
    }
    assert_true "agent_resolver_exists '$PLUGINS_DIR' '$first'" \
        "Resolver resolves a real agent name ('$first')"
}

run_test test_skill_subagent_types_resolve "Every SKILL.md subagent_type resolves to a real agent"
run_test test_resolver_finds_a_real_agent "Resolver resolves a known real agent (positive control)"
run_test test_crossref_detector_fires_on_fixture "Cross-ref detector fires on the dangling fixture"
run_test test_crossref_detector_fires_on_list_fixtures "Cross-ref gate fires on every name from list-form fixtures"

generate_report
