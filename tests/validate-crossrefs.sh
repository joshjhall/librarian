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
    tmp="$(/usr/bin/mktemp -d)"
    /usr/bin/mkdir -p "$tmp/p/skills/dangling-fixture"
    /usr/bin/cp "$fixture" "$tmp/p/skills/dangling-fixture/SKILL.md"

    local collected
    collected="$(collect_skill_subagent_types "$tmp")"
    /usr/bin/rm -rf "$tmp"

    assert_contains "$collected" "$bad_name" \
        "Collector extracts subagent_type '$bad_name' from the fixture frontmatter"
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

generate_report
