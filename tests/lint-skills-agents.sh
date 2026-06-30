#!/usr/bin/env bash
# Structural lint for Claude Code agent and skill definitions in the librarian
# plugins. Relocated from containers tests/unit/claude/lint_skills_agents.sh and
# retargeted from the single templates/claude/{skills,agents} tree to the three
# plugins under plugins/*/{skills,agents}.
#
# Validates:
# - Every skill dir has SKILL.md (+ metadata.yml where required)
# - Every agent dir has <name>.md with valid frontmatter
# - check-*/loop-*/context-* skills have required companion files
# - patterns.sh files are executable
# - Every workflow.js `export const meta` is a pure literal (no concat/interp)
# - Every workflow.js passes `node --check`
# - The meta pure-literal detector fires on a known-bad negative fixture
#
# No Docker required — pure filesystem + node checks against the plugins tree.
# Empty plugins (only .gitkeep placeholders) PASS: the discovery globs simply
# find no skill/agent dirs and the loops no-op. Containers-specific cross-file
# invariant tests (next-issue/orchestrate prose contracts, docs cross-refs) were
# intentionally NOT relocated — they validate containers product content, not
# artifact structure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PLUGINS_DIR="$REPO_ROOT/plugins"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/claude"

test_suite "Claude Agent/Skill Structural Lint"

# Valid values for frontmatter fields
VALID_MODELS="opus sonnet haiku"
VALID_TOOLS="Read Write Edit Bash Grep Glob Task WebFetch WebSearch"

# The shared "house floor" every fan-out workflow.js harness must use for its
# BUDGET_FLOOR (see workflow-authoring/SKILL.md § Budget Discipline). The harnesses
# run in a sandboxed JS engine with no import, so the constant is duplicated in
# each file; this value is the single source of truth the live sweep below pins
# every declaration to. Bump it here AND in every harness together.
HOUSE_BUDGET_FLOOR="40000"

# --- Discovery helpers ------------------------------------------------------
#
# Plugins live at plugins/<plugin>/{skills,agents}/<artifact>/. We enumerate
# artifact dirs across all three plugins. `command find` with -mindepth/-maxdepth
# selects exactly the artifact directories (one level below skills/ or agents/),
# and degrades cleanly to empty output when a plugin has only .gitkeep.

# List every agent markdown file across all plugins (absolute paths, sorted).
#
# Claude Code discovers plugin agents as FLAT markdown files directly under
# agents/ (agents/<name>.md), NOT nested in per-agent subdirectories — verified
# against the plugin loader and the official plugins. A few agents ship a
# workflow.js harness in a same-named sibling subdir (agents/<name>/workflow.js);
# that subdir is ignored by agent discovery and intentionally excluded here by
# matching only *.md one level under agents/.
list_agent_files() {
    command find "$PLUGINS_DIR" -mindepth 3 -maxdepth 3 -type f -path '*/agents/*' \
        -name '*.md' 2>/dev/null | command sort
}

# List every skill directory across all plugins (absolute paths, sorted).
list_skill_dirs() {
    command find "$PLUGINS_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/skills/*' \
        2>/dev/null | command sort
}

# List skill dirs whose basename matches a glob prefix (check-, loop-, context-).
list_skill_dirs_prefixed() {
    local prefix="$1"
    command find "$PLUGINS_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/skills/*' \
        -name "${prefix}*" 2>/dev/null | command sort
}

# Extract a YAML frontmatter value from a file.
# Usage: get_frontmatter_field <file> <field>
get_frontmatter_field() {
    local file="$1"
    local field="$2"
    /usr/bin/sed -n '/^---$/,/^---$/p' "$file" |
        command grep "^${field}:" |
        command sed "s/^${field}:[[:space:]]*//"
}

is_valid_value() {
    local value="$1"
    local list="$2"
    local item
    for item in $list; do
        [ "$value" = "$item" ] && return 0
    done
    return 1
}

# Report pure-literal violations in a workflow.js `export const meta` block, one
# token per line: "concat" (string concatenation) and/or "interp" (template
# interpolation). Empty output means the meta block is a pure literal.
#
# The Workflow tool rejects a non-literal meta object with "meta must be a pure
# literal" and silently disables the harness at load time. Shared by the live
# sweep and the negative-fixture self-test so the self-test proves the same
# regexes the live sweep relies on.
workflow_meta_violations() {
    local wf_file="$1"
    local meta_block
    meta_block="$(/usr/bin/awk '
        /export const meta/ { capturing = 1 }
        capturing {
            print
            depth += gsub(/{/, "{")
            depth -= gsub(/}/, "}")
            if (started && depth <= 0) exit
            if (depth > 0) started = 1
        }
    ' "$wf_file")"

    if printf '%s\n' "$meta_block" |
        command grep -qE "['\"][[:space:]]*[+]|[+][[:space:]]*['\"]"; then
        printf 'concat\n'
    fi
    if printf '%s\n' "$meta_block" | command grep -qF '${'; then
        printf 'interp\n'
    fi
}

# Capture the `export const meta { … }` block of a workflow.js as text. Shared
# by the meta-title extraction below; same brace-depth walk as
# workflow_meta_violations so both see exactly the same block.
workflow_meta_block() {
    local wf_file="$1"
    /usr/bin/awk '
        /export const meta/ { capturing = 1 }
        capturing {
            print
            depth += gsub(/{/, "{")
            depth -= gsub(/}/, "}")
            if (started && depth <= 0) exit
            if (depth > 0) started = 1
        }
    ' "$wf_file"
}

# Report phase()↔meta.phases inconsistencies in a workflow.js, one per line:
#   "phase-not-in-meta: <title>"  — a phase('<title>') call with no meta entry
#   "meta-not-in-phase: <title>"  — a meta.phases title with no phase() call
# Empty output means the two title sets are equal. A mismatch in either
# direction means the harness silently skips or duplicates a phase at runtime.
#
# Titles are the single/double-quoted string in `phase('X')` calls and in
# `title: 'X'` entries of the meta block. Shared by the live sweep and the
# negative-fixture self-test so the self-test exercises the live regexes.
workflow_phase_meta_mismatch() {
    local wf_file="$1"
    local meta_titles phase_titles
    meta_titles="$(workflow_meta_block "$wf_file" |
        command grep -oE "title:[[:space:]]*['\"][^'\"]+['\"]" |
        command sed -E "s/title:[[:space:]]*['\"]([^'\"]+)['\"]/\1/" |
        command sort -u)"
    phase_titles="$(command grep -oE "phase\([[:space:]]*['\"][^'\"]+['\"]" "$wf_file" |
        command sed -E "s/phase\([[:space:]]*['\"]([^'\"]+)['\"]/\1/" |
        command sort -u)"

    local title
    while IFS= read -r title; do
        [ -n "$title" ] || continue
        if ! printf '%s\n' "$meta_titles" | command grep -qxF "$title"; then
            printf 'phase-not-in-meta: %s\n' "$title"
        fi
    done <<<"$phase_titles"
    while IFS= read -r title; do
        [ -n "$title" ] || continue
        if ! printf '%s\n' "$phase_titles" | command grep -qxF "$title"; then
            printf 'meta-not-in-phase: %s\n' "$title"
        fi
    done <<<"$meta_titles"
}

# Report agentType references in a workflow.js that do not resolve to a real
# flat agent file at plugins/*/agents/<name>.md, one dangling name per line.
# Empty output means every agentType resolves. A dangling agentType means the
# harness invokes a nonexistent agent at runtime.
workflow_dangling_agenttypes() {
    local wf_file="$1"
    local name
    command grep -oE "agentType:[[:space:]]*['\"][^'\"]+['\"]" "$wf_file" |
        command sed -E "s/agentType:[[:space:]]*['\"]([^'\"]+)['\"]/\1/" |
        command sort -u |
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if [ -z "$(command find "$PLUGINS_DIR" -mindepth 3 -maxdepth 3 \
                -type f -path '*/agents/*' -name "${name}.md" 2>/dev/null)" ]; then
                printf '%s\n' "$name"
            fi
        done
}

# Echo the BUDGET_FLOOR value declared in a workflow.js, with underscore digit
# separators stripped (so `40_000` and `40000` compare equal), or nothing if the
# file declares no floor. Used to enforce that the cross-harness house floor
# (HOUSE_BUDGET_FLOOR below) stays identical across every fan-out harness — they
# run in a sandboxed JS engine with no shared-module import, so the constant is
# necessarily duplicated and a deterministic gate is the only consistency check.
# Only the first declaration is read; a harness with no fan-out simply omits it
# and is skipped by the live sweep.
workflow_budget_floor_value() {
    local wf_file="$1"
    command grep -oE "BUDGET_FLOOR[[:space:]]*=[[:space:]]*[0-9_]+" "$wf_file" |
        command head -n1 |
        command sed -E 's/.*=[[:space:]]*//; s/_//g'
}

# Report required_tools declared in a skill's metadata.yml whose command name is
# NOT referenced anywhere in the skill dir's *.sh/*.md, one per line. Empty
# output means every declared tool is referenced. A stale declaration (declared
# but never used) is drift the gate surfaces.
#
# Note: required_tools names are SHELL-COMMAND names (git, gh, grep, …), a
# different namespace than agent frontmatter `tools` (Read, Bash, …). The repo
# has no SKILL.md frontmatter `tools` field, so the gate validates the genuine
# contract that exists: declared shell tools must actually be used by the skill.
skill_unreferenced_required_tools() {
    local skill_dir="$1"
    local meta_file="$skill_dir/metadata.yml"
    [ -f "$meta_file" ] || return 0

    local names name
    names="$(/usr/bin/awk '
        /^required_tools:/ { c = 1; next }
        c && /^[a-zA-Z_]+:/ { c = 0 }
        c && /^[[:space:]]*-[[:space:]]*name:/ {
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
            gsub(/"/, "")
            print
        }
    ' "$meta_file")"

    # Reference search covers the skill's prose + scripts (*.md, *.sh) but NOT
    # metadata.yml itself — the tool name always appears there as its own
    # declaration, which would make every tool trivially "referenced". The file
    # list comes from `find` (one path per line) and is fed to grep -f via a
    # process substitution; /usr/bin/grep is used directly because the shell's
    # `grep` may be a ugrep wrapper whose `--include` glob filtering differs.
    local ref_files name
    ref_files="$(command find "$skill_dir" -type f \
        \( -name '*.sh' -o -name '*.md' \) 2>/dev/null)"

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        local found=""
        local f
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if /usr/bin/grep -qwE -- "$name" "$f" 2>/dev/null; then
                found=1
                break
            fi
        done <<<"$ref_files"
        [ -n "$found" ] || printf '%s\n' "$name"
    done <<<"$names"
}

# --- Agent Tests ------------------------------------------------------------

# Agent discovery yields flat agents/<name>.md files; the agent name is the
# file basename without the .md extension.

# Every plugin exposes at least the expected flat agent files (sanity: the
# loop bodies below no-op on an empty tree, so assert discovery is non-empty
# only when an agents/ dir actually holds content).
test_agent_files_exist() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        assert_file_exists "$agent_file" "Agent file missing: $agent_file"
    done < <(list_agent_files)
}

# Every agent has required frontmatter fields and name matches the filename.
test_agent_frontmatter_fields() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        local agent_name
        agent_name="$(/usr/bin/basename "$agent_file" .md)"

        local name_val description_val tools_val model_val
        name_val="$(get_frontmatter_field "$agent_file" "name")"
        description_val="$(get_frontmatter_field "$agent_file" "description")"
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        model_val="$(get_frontmatter_field "$agent_file" "model")"

        assert_not_empty "$name_val" "Agent $agent_name: missing 'name' in frontmatter"
        assert_not_empty "$description_val" "Agent $agent_name: missing 'description' in frontmatter"
        assert_not_empty "$tools_val" "Agent $agent_name: missing 'tools' in frontmatter"
        assert_not_empty "$model_val" "Agent $agent_name: missing 'model' in frontmatter"
        assert_equals "$name_val" "$agent_name" "Agent $agent_name: frontmatter name mismatch"
    done < <(list_agent_files)
}

# Agent model values are valid (opus/sonnet/haiku).
test_agent_model_values() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        local agent_name model_val
        agent_name="$(/usr/bin/basename "$agent_file" .md)"
        model_val="$(get_frontmatter_field "$agent_file" "model")"
        [ -z "$model_val" ] && continue
        if ! is_valid_value "$model_val" "$VALID_MODELS"; then
            assert_true false "Agent $agent_name: invalid model '$model_val' (expected: $VALID_MODELS)"
        fi
    done < <(list_agent_files)
}

# Agent tools values are from the valid set.
test_agent_tool_values() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        local agent_name tools_val
        agent_name="$(/usr/bin/basename "$agent_file" .md)"
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        [ -z "$tools_val" ] && continue

        local tool
        while IFS=',' read -ra TOOLS_ARRAY; do
            for tool in "${TOOLS_ARRAY[@]}"; do
                tool="$(printf '%s' "$tool" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [ -z "$tool" ] && continue
                if ! is_valid_value "$tool" "$VALID_TOOLS"; then
                    assert_true false "Agent $agent_name: invalid tool '$tool' (expected: $VALID_TOOLS)"
                fi
            done
        done <<<"$tools_val"
    done < <(list_agent_files)
}

# --- Skill Tests ------------------------------------------------------------

# Every skill directory has SKILL.md.
test_skill_files_exist() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        assert_file_exists "$skill_dir/SKILL.md" "Skill $skill_name missing SKILL.md"
    done < <(list_skill_dirs)
}

# Every skill has a description in its SKILL.md frontmatter.
test_skill_frontmatter() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name skill_file desc_val
        skill_name="$(/usr/bin/basename "$skill_dir")"
        skill_file="$skill_dir/SKILL.md"
        [ -f "$skill_file" ] || continue
        desc_val="$(get_frontmatter_field "$skill_file" "description")"
        assert_not_empty "$desc_val" "Skill $skill_name: missing 'description' in SKILL.md frontmatter"
    done < <(list_skill_dirs)
}

# metadata.yml name matches directory name (when metadata.yml is present).
test_skill_metadata_name_match() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name meta_file meta_name
        skill_name="$(/usr/bin/basename "$skill_dir")"
        meta_file="$skill_dir/metadata.yml"
        [ -f "$meta_file" ] || continue
        meta_name="$(command grep '^name:' "$meta_file" | command sed 's/^name:[[:space:]]*//')"
        [ -z "$meta_name" ] && continue
        assert_equals "$meta_name" "$skill_name" "Skill $skill_name: metadata.yml name mismatch"
    done < <(list_skill_dirs)
}

# check-* skills have the 5-file structure.
test_check_skill_structure() {
    local required_files="SKILL.md patterns.sh contract.md thresholds.yml metadata.yml"
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name file
        skill_name="$(/usr/bin/basename "$skill_dir")"
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "check-* skill $skill_name missing required file: $file"
        done
    done < <(list_skill_dirs_prefixed "check-")
}

# loop-* skills have the 5-file structure.
test_loop_skill_structure() {
    local required_files="SKILL.md patterns.sh contract.md thresholds.yml metadata.yml"
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name file
        skill_name="$(/usr/bin/basename "$skill_dir")"
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "loop-* skill $skill_name missing required file: $file"
        done
    done < <(list_skill_dirs_prefixed "loop-")
}

# context-* skills have the 3-file structure.
test_context_skill_structure() {
    local required_files="SKILL.md context.yml metadata.yml"
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name file
        skill_name="$(/usr/bin/basename "$skill_dir")"
        for file in $required_files; do
            assert_file_exists "$skill_dir/$file" \
                "context-* skill $skill_name missing required file: $file"
        done
    done < <(list_skill_dirs_prefixed "context-")
}

# patterns.sh files are executable.
test_patterns_sh_executable() {
    local patterns_file
    while IFS= read -r patterns_file; do
        [ -n "$patterns_file" ] || continue
        local skill_name
        skill_name="$(/usr/bin/basename "$(/usr/bin/dirname "$patterns_file")")"
        assert_true "[ -x '$patterns_file' ]" \
            "Skill $skill_name: patterns.sh is not executable"
    done < <(command find "$PLUGINS_DIR" -path '*/skills/*' -name "patterns.sh" -type f 2>/dev/null | command sort)
}

# --- Workflow Harness Tests -------------------------------------------------

# Every workflow.js `export const meta` block is a pure literal.
test_workflow_meta_pure_literal() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name violations
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        violations="$(workflow_meta_violations "$wf_file")"

        if printf '%s\n' "$violations" | command grep -qx "concat"; then
            assert_true false \
                "Workflow $rel_name: meta uses string concatenation (must be a single literal)"
        fi
        if printf '%s\n' "$violations" | command grep -qx "interp"; then
            assert_true false \
                "Workflow $rel_name: meta uses template interpolation (must be a pure literal)"
        fi
    done < <(command find "$PLUGINS_DIR" -name "workflow.js" -type f 2>/dev/null | command sort)
}

# Every bundled workflow.js parses with `node --check`. Skips when node is
# absent so a bash-only host degrades instead of failing; CI has node.
test_workflow_js_node_check() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot run 'node --check' on workflow.js files"
        return
    fi
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name node_err
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        if ! node_err="$(command node --check "$wf_file" 2>&1)"; then
            assert_true false \
                "Workflow $rel_name: workflow.js has a syntax error: ${node_err}"
        fi
    done < <(command find "$PLUGINS_DIR" -name "workflow.js" -type f 2>/dev/null | command sort)
}

# The meta pure-literal detector actually FIRES on a known-bad input. Without
# this, the live sweep above only ever proves the happy path. The committed
# negative fixture carries BOTH violation classes in its meta block.
test_workflow_meta_guard_detects_violations() {
    local fixture="$FIXTURES_DIR/workflow_meta_bad.js"
    assert_file_exists "$fixture" "Negative meta fixture exists"
    [ -f "$fixture" ] || return 0

    local violations
    violations="$(workflow_meta_violations "$fixture")"
    assert_contains "$violations" "concat" \
        "Detector flags string concatenation in the bad fixture's meta block"
    assert_contains "$violations" "interp" \
        "Detector flags template interpolation in the bad fixture's meta block"
}

# `node --check` actually FIRES on a syntax error — proves the node-check sweep
# is not passing vacuously (e.g. a node stub that always exits 0). Uses a
# throwaway temp file rather than a committed broken .js (which would itself
# trip the live sweep).
test_workflow_js_node_check_detects_syntax_error() {
    if ! command -v node >/dev/null 2>&1; then
        skip_test "node not available — cannot prove node --check fires"
        return
    fi
    local bad
    bad="$(/usr/bin/mktemp --suffix=.js)"
    printf 'function broken( {\n  return 1\n' >"$bad"
    local err rc=0
    err="$(command node --check "$bad" 2>&1)" || rc=$?
    command rm -f "$bad"
    assert_true "[ $rc -ne 0 ]" "node --check exits non-zero on a syntax error"
    assert_contains "$err" "SyntaxError" "node --check reports a SyntaxError"
}

# Every workflow.js has consistent phase()↔meta.phases title sets (live sweep).
test_workflow_phase_meta_consistency() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name mismatch
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        mismatch="$(workflow_phase_meta_mismatch "$wf_file")"
        if [ -n "$mismatch" ]; then
            assert_true false \
                "Workflow $rel_name: phase()/meta.phases mismatch: $(printf '%s' "$mismatch" | command tr '\n' '; ')"
        fi
    done < <(command find "$PLUGINS_DIR" -name "workflow.js" -type f 2>/dev/null | command sort)
}

# The phase↔meta detector FIRES on the negative fixture — in BOTH directions.
test_workflow_phase_guard_detects_mismatch() {
    local fixture="$FIXTURES_DIR/workflow_phase_bad.js"
    assert_file_exists "$fixture" "Negative phase-mismatch fixture exists"
    [ -f "$fixture" ] || return 0

    local mismatch
    mismatch="$(workflow_phase_meta_mismatch "$fixture")"
    assert_contains "$mismatch" "phase-not-in-meta: Ghost" \
        "Detector flags a phase() call absent from meta.phases"
    assert_contains "$mismatch" "meta-not-in-phase: Orphan" \
        "Detector flags a meta.phases entry with no phase() call"
}

# Every agentType referenced in a workflow.js resolves to a real agent file.
test_workflow_agenttype_resolves() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name dangling
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        dangling="$(workflow_dangling_agenttypes "$wf_file")"
        if [ -n "$dangling" ]; then
            assert_true false \
                "Workflow $rel_name: agentType has no plugins/*/agents/<name>.md: $(printf '%s' "$dangling" | command tr '\n' ' ')"
        fi
    done < <(command find "$PLUGINS_DIR" -name "workflow.js" -type f 2>/dev/null | command sort)
}

# The agentType cross-ref detector FIRES on the negative fixture.
test_workflow_agenttype_guard_detects_dangling() {
    local fixture="$FIXTURES_DIR/workflow_agenttype_bad.js"
    assert_file_exists "$fixture" "Negative dangling-agentType fixture exists"
    [ -f "$fixture" ] || return 0

    local dangling
    dangling="$(workflow_dangling_agenttypes "$fixture")"
    assert_contains "$dangling" "nonexistent-agent" \
        "Detector flags an agentType with no matching agent file"
}

# Every workflow.js that declares a BUDGET_FLOOR uses the house value. The
# constant cannot live in a shared module (sandboxed JS engine, no import), so it
# is duplicated across the fan-out harnesses; this live sweep is the only thing
# keeping the 6 copies in lockstep. A harness with no fan-out omits the floor and
# is skipped — only a declared-but-divergent value fails.
test_workflow_budget_floor_consistent() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name value
        rel_name="$(/usr/bin/basename "$(/usr/bin/dirname "$wf_file")")"
        value="$(workflow_budget_floor_value "$wf_file")"
        [ -n "$value" ] || continue
        assert_equals "$HOUSE_BUDGET_FLOOR" "$value" \
            "Workflow $rel_name: BUDGET_FLOOR ($value) must equal the house floor ($HOUSE_BUDGET_FLOOR)"
    done < <(command find "$PLUGINS_DIR" -name "workflow.js" -type f 2>/dev/null | command sort)
}

# The BUDGET_FLOOR consistency detector FIRES on the negative fixture: the fixture
# declares a non-house floor, and the value it reports back must differ from the
# house value (proving the assert_equals in the live sweep would fail on drift).
test_workflow_budget_floor_guard_detects_drift() {
    local fixture="$FIXTURES_DIR/workflow_budgetfloor_bad.js"
    assert_file_exists "$fixture" "Negative budget-floor fixture exists"
    [ -f "$fixture" ] || return 0

    local value
    value="$(workflow_budget_floor_value "$fixture")"
    assert_not_empty "$value" "Detector reads a BUDGET_FLOOR value from the fixture"
    if [ "$value" = "$HOUSE_BUDGET_FLOOR" ]; then
        assert_true false \
            "Negative fixture must declare a NON-house floor so the guard has drift to catch"
    fi
}

# Every required_tools entry in a skill's metadata.yml is referenced in the
# skill dir (live sweep over all skills carrying required_tools).
test_skill_required_tools_referenced() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name unreferenced
        skill_name="$(/usr/bin/basename "$skill_dir")"
        unreferenced="$(skill_unreferenced_required_tools "$skill_dir")"
        if [ -n "$unreferenced" ]; then
            assert_true false \
                "Skill $skill_name: required_tools declared but not referenced in *.sh/*.md: $(printf '%s' "$unreferenced" | command tr '\n' ' ')"
        fi
    done < <(list_skill_dirs)
}

# The required_tools reference detector FIRES on the negative fixture: it flags
# the unreferenced `kubectl` but NOT the referenced `grep`.
test_skill_required_tools_guard_detects_drift() {
    local fixture="$FIXTURES_DIR/skill_tooldrift_bad"
    assert_file_exists "$fixture/metadata.yml" "Negative tool-drift fixture exists"
    [ -f "$fixture/metadata.yml" ] || return 0

    local unreferenced
    unreferenced="$(skill_unreferenced_required_tools "$fixture")"
    assert_contains "$unreferenced" "kubectl" \
        "Detector flags a declared-but-unreferenced required tool"
    if printf '%s\n' "$unreferenced" | command grep -qx "grep"; then
        assert_true false \
            "Detector must NOT flag the referenced tool 'grep' in the fixture"
    fi
}

# --- Run All Tests ----------------------------------------------------------

run_test test_agent_files_exist "Every agent has correctly named .md file"
run_test test_agent_frontmatter_fields "Every agent has required frontmatter fields"
run_test test_agent_model_values "Agent model values are valid (opus/sonnet/haiku)"
run_test test_agent_tool_values "Agent tool values are from valid set"
run_test test_skill_files_exist "Every skill has SKILL.md"
run_test test_skill_frontmatter "Every skill has description in frontmatter"
run_test test_skill_metadata_name_match "Skill metadata.yml name matches directory"
run_test test_check_skill_structure "check-* skills have 5-file structure"
run_test test_loop_skill_structure "loop-* skills have 5-file structure"
run_test test_context_skill_structure "context-* skills have 3-file structure"
run_test test_patterns_sh_executable "patterns.sh files are executable"
run_test test_workflow_meta_pure_literal "Every workflow.js meta is a pure literal (no concat/interpolation)"
run_test test_workflow_js_node_check "Every workflow.js passes node --check (syntax valid)"
run_test test_workflow_js_node_check_detects_syntax_error "node --check guard fires on a syntax error"
run_test test_workflow_meta_guard_detects_violations "Meta pure-literal guard fires on the negative fixture"
run_test test_workflow_phase_meta_consistency "Every workflow.js phase() set matches meta.phases"
run_test test_workflow_phase_guard_detects_mismatch "Phase↔meta guard fires on the negative fixture"
run_test test_workflow_agenttype_resolves "Every workflow.js agentType resolves to an agent file"
run_test test_workflow_agenttype_guard_detects_dangling "agentType cross-ref guard fires on the negative fixture"
run_test test_workflow_budget_floor_consistent "Every workflow.js BUDGET_FLOOR equals the house floor"
run_test test_workflow_budget_floor_guard_detects_drift "BUDGET_FLOOR consistency guard fires on the negative fixture"
run_test test_skill_required_tools_referenced "Every skill's required_tools are referenced in the skill"
run_test test_skill_required_tools_guard_detects_drift "required_tools reference guard fires on the negative fixture"

generate_report
