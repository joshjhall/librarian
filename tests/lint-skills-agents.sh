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
# - Every agent's `## Restrictions` carries the #426 destructive-shell clause
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
VALID_MODELS="fable opus sonnet haiku inherit"
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
    command sed -n '/^---$/,/^---$/p' "$file" |
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

# Print an agent file's `## Restrictions` section body (heading excluded), up to
# the next `## ` heading or EOF.
#
# Scoping the #426 clause check to this section is load-bearing, not tidiness.
# code-reviewer.md carries the string `#426` in its Tool Rationale TABLE while
# its Restrictions bullet had lost the marker — a whole-file grep reports that
# file compliant and the gate then passes identically before and after the fix it
# is supposed to enforce. Every agent uses this exact heading, so an agent that
# renames or drops the section yields empty output here and fails the sweep on
# all four tokens rather than passing by omission.
agent_restrictions_section() {
    command awk '
        /^## Restrictions[[:space:]]*$/ { capturing = 1; next }
        capturing && /^## / { exit }
        capturing { print }
    ' "$1"
}

# Print the Restrictions section one BULLET per line: a leading `- `/`* ` item
# with its indented continuation lines folded onto the same line.
#
# The clause is checked per-bullet rather than per-section so the four tokens must
# co-occur in ONE prohibition. Checking the section as a whole would let an editor
# delete the clause entirely and still pass on incidental co-occurrence — one
# bullet citing `#426`, another using the word "unresolved" — which is #426's own
# failure mode (technically compliant prose, no actual restriction) reproduced one
# level up in the gate meant to close it. Verified against all 18 agents: every
# real clause, including checker.md's agnix-extended and debugger.md's
# write-capable rewordings, states the invariant in a single bullet.
agent_restrictions_bullets() {
    agent_restrictions_section "$1" | command awk '
        /^[-*] /            { if (bullet != "") print bullet; bullet = $0; next }
        /^[[:space:]]+[^ ]/ { if (bullet != "") bullet = bullet " " $0; next }
                            { if (bullet != "") print bullet; bullet = "" }
        END                 { if (bullet != "") print bullet }
    '
}

# Report which parts of the #426 destructive-shell clause are MISSING, one token
# name per line. Empty output = compliant, meaning SOME single bullet in the
# agent's Restrictions section carries the whole invariant. A non-empty report
# describes the closest bullet found — the most actionable near-miss — so it is a
# diagnostic message, not an exhaustive list of everything the section lacks.
#
# #426: a nominally read-only reviewer subagent ran destructive shell against the
# LIVE working tree and was technically compliant, because the prose banned file
# mutation but not the shell that performs it. The prose clause is the belt;
# plugins/workflow/hooks/bash-guard.sh is the braces. This detector keeps the belt
# honest across all the hand-copied copies.
#
# It asserts an invariant CORE, not a fixed sentence: the sandbox (`mktemp -d`),
# path canonicalization, the no-unresolved-`..` rule, and the `#426` provenance
# marker that tells a future editor why the clause exists. Per-agent adaptations
# stay legal — checker.md extends it with agnix autofix fencing, debugger.md
# reframes it for a write-capable agent — as long as all four survive. Normalizing
# every copy to identical text would break those adaptations; this does not.
#
# Scope, so nobody reads more into a pass than it means: this catches DELETION and
# DRIFT — the failure this repo actually saw, where a hand-copied clause quietly
# lost a piece. It is a token check, not semantic analysis, so a single bullet
# carrying all four tokens with inverted meaning would pass. That residual is
# accepted: the prose clause is only the belt, and
# plugins/workflow/hooks/bash-guard.sh enforces the ban at the tool level for
# every Bash-capable subagent regardless of what any agent file says.
#
# The scans use a here-string, NOT `printf ... | grep -q`. `grep -q` exits at the
# first match and closes the pipe, so a large enough left-hand side takes SIGPIPE
# and the pipeline reports 141 under `set -o pipefail` — the `||` then fires and
# reports a token as missing that is demonstrably present. Observed here against
# the largest agent (checker.md, ~39 KB): intermittent, size-dependent, and it
# fails in the unsafe direction for a security gate that must not cry wolf. A
# here-string has no writer process, so there is nothing to signal.
agent_missing_clause_tokens() {
    local bullet best_missing="mktemp canonicalize unresolved provenance" missing

    # Score every bullet INDEPENDENTLY and keep the best (fewest tokens missing);
    # a bullet is never combined with any other. Two earlier shapes both failed by
    # letting a second bullet rescue the first: grepping the section as a whole,
    # and grepping all `mktemp -d`-bearing bullets into one blob (an agent whose
    # clause bullet carried only the sandbox then passed on a sibling bullet's
    # wording). Both are the same #426 failure mode — technically compliant prose
    # stating no actual restriction — so the loop evaluates one bullet at a time
    # and no cross-bullet path exists to reintroduce it.
    #
    # With no bullets at all (no Restrictions section, or an empty one), the
    # initial value stands and the whole invariant is reported missing — the
    # section fails loudly rather than passing by omission.
    while IFS= read -r bullet; do
        [ -n "$bullet" ] || continue
        missing=""
        command grep -qF 'mktemp -d' <<<"$bullet" || missing="$missing mktemp"
        command grep -qi 'canonicali' <<<"$bullet" || missing="$missing canonicalize"
        command grep -qi 'unresolved' <<<"$bullet" || missing="$missing unresolved"
        command grep -qF '#426' <<<"$bullet" || missing="$missing provenance"
        missing="${missing# }"

        [ -z "$missing" ] && return 0 # a fully compliant bullet: nothing missing
        # Fewer missing tokens = closer to the real clause, so its report is the
        # most actionable one to show the editor.
        if [ "$(printf '%s' "$missing" | command wc -w)" \
            -lt "$(printf '%s' "$best_missing" | command wc -w)" ]; then
            best_missing="$missing"
        fi
    done <<<"$(agent_restrictions_bullets "$1")"

    # Deliberately unquoted: word-splitting turns the space-separated accumulator
    # back into this function's documented one-token-per-line output. The tokens
    # are fixed literals from this function, so there is nothing to glob or
    # inject.
    #
    # Quoting would emit one space-joined line instead. Checked by hand, not by
    # any test here: that breaks nothing today, because every current caller
    # pipes through `tr '\n' ' '` and both forms normalize identically. So the
    # split is kept for the contract rather than to prevent a live breakage — a
    # future caller reading line-by-line is what it protects, and no assertion
    # will tell you if that stops being true.
    # shellcheck disable=SC2086
    printf '%s\n' $best_missing
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
    meta_block="$(command awk '
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
    command awk '
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

# Report agentType references in a workflow.js that do not resolve under the
# Workflow tool's runtime registry, one dangling ref per line. Empty output
# means every agentType resolves.
#
# The Workflow tool's agent() resolver keys agents ONLY by their namespaced
# `<plugin>:<name>` form (`dev-core:code-reviewer`, `review-audit:checker`, …) —
# the OPPOSITE of the Agent tool's `subagent_type`, which takes the bare name.
# So a valid agentType MUST be `<plugin>:<name>` AND map to a real flat agent
# file at plugins/<plugin>/agents/<name>.md. A bare name (no colon) is reported
# as dangling even when its basename resolves, because that is exactly what
# throws at runtime under a marketplace install (issue #126).
workflow_dangling_agenttypes() {
    local wf_file="$1"
    local ref plugin name
    command grep -oE "agentType:[[:space:]]*['\"][^'\"]+['\"]" "$wf_file" |
        command sed -E "s/agentType:[[:space:]]*['\"]([^'\"]+)['\"]/\1/" |
        command sort -u |
        while IFS= read -r ref; do
            [ -n "$ref" ] || continue
            case "$ref" in
                *:*)
                    plugin="${ref%%:*}"
                    name="${ref#*:}"
                    if [ ! -f "$PLUGINS_DIR/$plugin/agents/${name}.md" ]; then
                        printf '%s\n' "$ref"
                    fi
                    ;;
                *)
                    # Bare name — resolves under the Agent tool but throws under
                    # the Workflow tool. Always dangling here.
                    printf '%s\n' "$ref"
                    ;;
            esac
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
#
# The pattern is anchored to a `const` declaration so a comment that merely
# mentions the constant (e.g. `// previously BUDGET_FLOOR = 50_000`) cannot
# shadow the real value via head -n1.
workflow_budget_floor_value() {
    local wf_file="$1"
    command grep -oE "const[[:space:]]+BUDGET_FLOOR[[:space:]]*=[[:space:]]*[0-9_]+" "$wf_file" |
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
    names="$(command awk '
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
            if command grep -qwE -- "$name" "$f" 2>/dev/null; then
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
        agent_name="$(command basename "$agent_file" .md)"

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

# Agent model values are valid (fable/opus/sonnet/haiku/inherit).
test_agent_model_values() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        local agent_name model_val
        agent_name="$(command basename "$agent_file" .md)"
        model_val="$(get_frontmatter_field "$agent_file" "model")"
        [ -z "$model_val" ] && continue
        if ! is_valid_value "$model_val" "$VALID_MODELS"; then
            assert_true false "Agent $agent_name: invalid model '$model_val' (expected: $VALID_MODELS)"
        fi
    done < <(list_agent_files)
}

# Report the invalid tokens in a comma-separated agent `tools:` value, one per
# line (empty output = all valid). A scoped grant like `Bash(git diff:*)` (a
# per-command Bash allowlist — see code-reviewer.md, #426) validates by its base
# tool name: a trailing `(...)` scope suffix is stripped before the membership
# check, so `Bash(git diff:*)` is valid but `Frob(x:*)` is not.
invalid_tools_in_line() {
    local tools_val="$1"
    local tool base
    while IFS=',' read -ra TOOLS_ARRAY; do
        for tool in "${TOOLS_ARRAY[@]}"; do
            tool="$(printf '%s' "$tool" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -z "$tool" ] && continue
            base="${tool%%(*}"
            is_valid_value "$base" "$VALID_TOOLS" || printf '%s\n' "$tool"
        done
    done <<<"$tools_val"
}

# Agent tools values are from the valid set.
test_agent_tool_values() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        local agent_name tools_val invalid
        agent_name="$(command basename "$agent_file" .md)"
        tools_val="$(get_frontmatter_field "$agent_file" "tools")"
        [ -z "$tools_val" ] && continue

        invalid="$(invalid_tools_in_line "$tools_val")"
        assert_equals "" "$invalid" \
            "Agent $agent_name: invalid tool(s) '$(printf '%s' "$invalid" | command tr '\n' ' ')' (expected base names from: $VALID_TOOLS)"
    done < <(list_agent_files)
}

# The tool-value guard FIRES on invalid base names and PASSES a valid scoped
# Bash allowlist — proving the `(...)` scope strip (#426) narrows the base name,
# not the whole check.
test_agent_tool_values_guard() {
    local scoped invalid
    scoped="Read, Grep, Bash(git diff:*), Bash(wc:*)"
    assert_equals "" "$(invalid_tools_in_line "$scoped")" \
        "A read-only scoped-Bash allowlist must validate (base names are valid)"
    invalid="$(invalid_tools_in_line "Read, Frob(x:*), Bash")"
    assert_contains "$invalid" "Frob(x:*)" \
        "An invalid base name (Frob) must still be flagged even when scoped"
}

# --- Skill Tests ------------------------------------------------------------

# Every skill directory has SKILL.md.
test_skill_files_exist() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name
        skill_name="$(command basename "$skill_dir")"
        assert_file_exists "$skill_dir/SKILL.md" "Skill $skill_name missing SKILL.md"
    done < <(list_skill_dirs)
}

# Every skill has a description in its SKILL.md frontmatter.
test_skill_frontmatter() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name skill_file desc_val
        skill_name="$(command basename "$skill_dir")"
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
        skill_name="$(command basename "$skill_dir")"
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
        skill_name="$(command basename "$skill_dir")"
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
        skill_name="$(command basename "$skill_dir")"
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
        skill_name="$(command basename "$skill_dir")"
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
        skill_name="$(command basename "$(command dirname "$patterns_file")")"
        assert_true "[ -x '$patterns_file' ]" \
            "Skill $skill_name: patterns.sh is not executable"
    done < <(command find "$PLUGINS_DIR" -path '*/skills/*' -name "patterns.sh" -type f 2>/dev/null | command sort)
}

# EVERY bundled .sh under plugins/ is executable — not just skills' patterns.sh.
#
# The narrower check above left every sibling script ungated: the scanners a
# skill body invokes by path (ship-issue/pre-review-gates.sh), the workflow
# plugin's scripts/, and the bundled hooks/. #604 lost pre-review-gates.sh's
# executable bit to a `cp`-based restore and nothing caught it — the mode change
# rode along in the diff, invisible to `git diff --stat` (only `--summary` and
# the raw diff show a mode line) and outside the patterns.sh glob.
#
# These ship to users via `claude plugin install`, where the mode is what the
# tarball carries. A skill that documents `${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh`
# as a bare invocation breaks outright without the bit; one invoked as
# `bash foo.sh` merely works by accident. Gate the whole tree so the next
# accidental chmod fails here rather than in a user's install.
test_bundled_shell_scripts_executable() {
    local sh_file rel
    while IFS= read -r sh_file; do
        [ -n "$sh_file" ] || continue
        rel="${sh_file#"$PLUGINS_DIR"/}"
        assert_true "[ -x '$sh_file' ]" \
            "Bundled script is not executable: plugins/$rel"
    done < <(command find "$PLUGINS_DIR" -name '*.sh' -type f 2>/dev/null | command sort)
}

# --- Workflow Harness Tests -------------------------------------------------

# Every workflow.js `export const meta` block is a pure literal.
test_workflow_meta_pure_literal() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name violations
        rel_name="$(command basename "$(command dirname "$wf_file")")"
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
        rel_name="$(command basename "$(command dirname "$wf_file")")"
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
    bad="$(command mktemp --suffix=.js)"
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
        rel_name="$(command basename "$(command dirname "$wf_file")")"
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

# Every agentType in a workflow.js is the namespaced <plugin>:<name> form the
# Workflow tool's registry resolves — a bare name throws at runtime (issue #126).
test_workflow_agenttype_resolves() {
    local wf_file
    while IFS= read -r wf_file; do
        [ -n "$wf_file" ] || continue
        [ -f "$wf_file" ] || continue
        local rel_name dangling
        rel_name="$(command basename "$(command dirname "$wf_file")")"
        dangling="$(workflow_dangling_agenttypes "$wf_file")"
        if [ -n "$dangling" ]; then
            assert_true false \
                "Workflow $rel_name: agentType not a resolvable <plugin>:<name>: $(printf '%s' "$dangling" | command tr '\n' ' ')"
        fi
    done < <(command find "$PLUGINS_DIR" -name "workflow.js" -type f 2>/dev/null | command sort)
}

# The detector FIRES on a namespaced-but-unresolvable agentType.
test_workflow_agenttype_guard_detects_dangling() {
    local fixture="$FIXTURES_DIR/workflow_agenttype_bad.js"
    assert_file_exists "$fixture" "Negative dangling-agentType fixture exists"
    [ -f "$fixture" ] || return 0

    local dangling
    dangling="$(workflow_dangling_agenttypes "$fixture")"
    assert_contains "$dangling" "workflow:nonexistent-agent" \
        "Detector flags a namespaced agentType with no matching agent file"
}

# The detector FIRES on a BARE agentType — resolvable by basename but invalid
# for the Workflow tool, which is precisely the issue #126 class.
test_workflow_agenttype_guard_detects_bare() {
    local fixture="$FIXTURES_DIR/workflow_agenttype_bare.js"
    assert_file_exists "$fixture" "Negative bare-agentType fixture exists"
    [ -f "$fixture" ] || return 0

    local dangling
    dangling="$(workflow_dangling_agenttypes "$fixture")"
    assert_contains "$dangling" "code-reviewer" \
        "Detector flags a bare agentType even when its basename resolves"
}

# Every workflow.js that declares a BUDGET_FLOOR uses the house value. The
# constant cannot live in a shared module (sandboxed JS engine, no import), so it
# is duplicated across the fan-out harnesses; this live sweep is the only thing
# keeping the 6 copies in lockstep. A harness with no fan-out omits the floor and
# is skipped — only a declared-but-divergent value fails.
# RETIRED as a live sweep, SUBSUMED by tests/validate-prelude-sync.sh (#586).
#
# The sweep used to assert every harness's hand-written BUDGET_FLOOR equalled the
# house value. There are no longer six hand-written declarations to compare: the
# constant is declared once in plugins/lib/prelude.js and copied into each
# consumer by bin/generate-prelude.mjs, so the prelude gate pins the house value
# at the source and pins every copy byte-equal to it.
#
# Two properties of the old test are deliberately preserved rather than dropped,
# because "subsumed" must not quietly mean "narrowed":
#
#   1. THE HOUSE VALUE ITSELF is asserted by validate-prelude-sync.sh's
#      test_source_declares_house_budget_floor.
#   2. NO SECOND DECLARATION may reappear outside the generated region — the
#      actual drift this gate existed to prevent. Asserted there too, by
#      test_no_harness_declares_budget_floor_twice, which counts declarations per
#      harness across plugins/**/workflow.js.
#
# `workflow_budget_floor_value` is KEPT and still exercised by
# test_workflow_budget_floor_guard_detects_drift below: that test pins the
# EXTRACTOR's precision (exact value, no partial match, empty for a floorless
# file), which is a property of this file's parsing helpers and has no equivalent
# in the sync gate. Deleting it would lose coverage rather than move it.

# The BUDGET_FLOOR consistency detector FIRES on the negative fixture: the fixture
# declares a non-house floor (99000), and the value it reports back must be that
# exact value — proving both that the extraction is precise (no partial match)
# and that the assert_equals in the live sweep would fail on drift. Also pins the
# skip path: a workflow.js with NO floor must yield empty so the live sweep's
# `[ -n "$value" ] || continue` skips it rather than validating it.
test_workflow_budget_floor_guard_detects_drift() {
    local fixture="$FIXTURES_DIR/workflow_budgetfloor_bad.js"
    assert_file_exists "$fixture" "Negative budget-floor fixture exists"
    [ -f "$fixture" ] || return 0

    local value
    value="$(workflow_budget_floor_value "$fixture")"
    assert_equals "99000" "$value" \
        "Detector extracts the exact non-house floor from the bad fixture"
    if [ "$value" = "$HOUSE_BUDGET_FLOOR" ]; then
        assert_true false \
            "Negative fixture must declare a NON-house floor so the guard has drift to catch"
    fi

    # Skip-path coverage: a fixture with no BUDGET_FLOOR declaration yields empty,
    # so the live sweep skips it instead of asserting against the house value.
    local nofloor="$FIXTURES_DIR/workflow_agenttype_bad.js"
    if [ -f "$nofloor" ]; then
        assert_equals "" "$(workflow_budget_floor_value "$nofloor")" \
            "Detector returns empty for a workflow.js with no BUDGET_FLOOR"
    fi
}

# Every required_tools entry in a skill's metadata.yml is referenced in the
# skill dir (live sweep over all skills carrying required_tools).
test_skill_required_tools_referenced() {
    local skill_dir
    while IFS= read -r skill_dir; do
        [ -n "$skill_dir" ] || continue
        local skill_name unreferenced
        skill_name="$(command basename "$skill_dir")"
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

# Every agent carries the #426 destructive-shell clause in its Restrictions
# section (live sweep). All agents in this repo hold Bash, so the sweep is
# universal and there is no exemption list — an exemption list would be
# empty-by-rights today and would only be somewhere for future drift to hide.
test_agent_destructive_clause_present() {
    local agent_file
    while IFS= read -r agent_file; do
        [ -n "$agent_file" ] || continue
        [ -f "$agent_file" ] || continue
        local missing
        missing="$(agent_missing_clause_tokens "$agent_file")"
        if [ -n "$missing" ]; then
            assert_true false \
                "Agent $(command basename "$agent_file"): Restrictions section omits the #426 destructive-shell clause — missing: $(printf '%s' "$missing" | command tr '\n' ' ')"
        fi
    done < <(list_agent_files)
}

# The clause detector FIRES on the negative fixture and stays QUIET on the
# positive one.
#
# The negative assertion pins the EXACT missing-token set, not merely that
# something was reported: a detector that reported one token for every file would
# satisfy a non-empty check while catching nothing. The positive fixture states
# the clause in wording that matches no real agent verbatim, so it fails first if
# the detector is ever tightened into a literal-string match — which would break
# checker.md's and debugger.md's legitimate adaptations.
test_agent_destructive_clause_guard_detects_drift() {
    local bad="$FIXTURES_DIR/agent_clause_bad.md"
    local good="$FIXTURES_DIR/agent_clause_good.md"

    assert_file_exists "$bad" "Negative destructive-clause fixture exists"
    assert_file_exists "$good" "Positive destructive-clause fixture exists"
    [ -f "$bad" ] && [ -f "$good" ] || return 0

    assert_equals "mktemp canonicalize unresolved provenance" \
        "$(agent_missing_clause_tokens "$bad" | command tr '\n' ' ' | command sed 's/ $//')" \
        "Detector reports every invariant token as missing on the clause-free fixture"

    assert_equals "" "$(agent_missing_clause_tokens "$good")" \
        "Detector accepts a reworded clause carrying all four invariant tokens"

    # Per-bullet, not per-section: the scattered fixture has all four tokens
    # somewhere in Restrictions but no bullet that actually states the
    # prohibition. A section-wide sweep passes it; this must not.
    local scattered="$FIXTURES_DIR/agent_clause_scattered.md"
    assert_file_exists "$scattered" "Scattered-token fixture exists"
    if [ -f "$scattered" ]; then
        assert_equals "canonicalize unresolved provenance" \
            "$(agent_missing_clause_tokens "$scattered" | command tr '\n' ' ' | command sed 's/ $//')" \
            "Detector rejects tokens scattered across unrelated bullets"
    fi

    # Nor is it "all mktemp-bearing bullets merged": two bullets each mention the
    # sandbox and neither states the full invariant, so a blob anchor satisfies
    # all four tokens across them and passes. Scoring each bullet alone must
    # report the near-miss instead.
    local twomk="$FIXTURES_DIR/agent_clause_twomktemp.md"
    assert_file_exists "$twomk" "Two-mktemp-bullet fixture exists"
    if [ -f "$twomk" ]; then
        assert_equals "provenance" \
            "$(agent_missing_clause_tokens "$twomk" | command tr '\n' ' ' | command sed 's/ $//')" \
            "Detector never merges two sandbox-mentioning bullets into one clause"
    fi

    # Partial-miss precision: drop ONLY the provenance marker from the positive
    # fixture — the historical code-reviewer.md defect — and the report must name
    # exactly `provenance`. Pins each token's check as independent, which neither
    # the all-missing nor the none-missing case can show. Built in a mktemp -d
    # sandbox; the fixture on disk is never modified.
    local sandbox
    sandbox="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$sandbox" ] && [ -d "$sandbox" ]; then
        command sed 's/ (#426)\././' "$good" >"$sandbox/partial.md"
        assert_equals "provenance" \
            "$(agent_missing_clause_tokens "$sandbox/partial.md" | command tr '\n' ' ' | command sed 's/ $//')" \
            "Detector reports only the dropped token when the rest of the clause is intact"
        command rm -rf "$sandbox"
    else
        skip_test "mktemp -d unavailable — partial-miss precision case skipped"
    fi

    # Section-scoping is what makes the code-reviewer.md case (#426 in the Tool
    # Rationale table, absent from the bullet) detectable. Prove the extractor
    # really is bounded: the fixture's Output Format section sits after
    # Restrictions and must not be scanned.
    if agent_restrictions_section "$good" | command grep -q '^## '; then
        assert_true false \
            "Restrictions extractor must stop at the next heading, not run to EOF"
    fi

    # A file with NO Restrictions heading yields an empty section, so the sweep
    # fails it on the whole invariant rather than passing it by omission. Any
    # agent file without the heading exercises this; workflow.js harnesses do not
    # have one.
    local noheading="$FIXTURES_DIR/skill_tooldrift_bad/SKILL.md"
    if [ -f "$noheading" ]; then
        assert_equals "" "$(agent_restrictions_section "$noheading")" \
            "Extractor returns empty for a file with no Restrictions heading"
        assert_equals "mktemp canonicalize unresolved provenance" \
            "$(agent_missing_clause_tokens "$noheading" | command tr '\n' ' ' | command sed 's/ $//')" \
            "A missing Restrictions section fails the invariant, never passes by omission"
    fi

    # A section with bullets but NO sandbox mention anywhere still fails, and
    # fails on more than the anchor token. An earlier shape special-cased "no
    # anchor found" by falling back to a section-wide scan of the other three
    # tokens, which let them be satisfied across unrelated bullets and reported
    # only `mktemp` — the very co-occurrence hole the per-bullet design closes,
    # surviving in the branch that handles its absence. Scoring per bullet, the
    # closest bullet here carries just one token, so `mktemp` plus the two it
    # also lacks are reported.
    local sandbox2
    sandbox2="$(mktemp -d 2>/dev/null || true)"
    if [ -n "$sandbox2" ] && [ -d "$sandbox2" ]; then
        {
            printf '## Restrictions\n\nMUST NOT:\n\n'
            printf -- '- Canonicalize the findings payload before emitting it\n'
            printf -- '- Leave an unresolved placeholder in generated output\n'
            printf -- '- Skip the schema check introduced in #426\n\n'
            printf '## Output Format\n\nNothing.\n'
        } >"$sandbox2/noanchor.md"
        assert_equals "mktemp unresolved provenance" \
            "$(agent_missing_clause_tokens "$sandbox2/noanchor.md" | command tr '\n' ' ' | command sed 's/ $//')" \
            "No sandbox bullet: reports more than the anchor token, never rescued section-wide"

        # Heading present, body empty — the same zero-bullet state as the
        # no-heading case above, reached by a different path (the extractor finds
        # its section and returns nothing from it, rather than never matching).
        # Both pin the same OUTCOME: zero bullets can never read as compliant.
        # The regression they catch together is a plausible refactor that
        # early-returns empty when the section yields no bullets; measured, that
        # mutation fails both assertions, so this one is deliberate overlap on
        # the second input shape rather than unique coverage.
        #
        # It pins the outcome, not an internal step: `agent_restrictions_bullets`
        # emits nothing here, but a `<<<` here-string of the empty string still
        # yields one empty-line iteration, which the `[ -n "$bullet" ]` guard
        # skips. That guard is belt-and-braces for this shape — measured, an
        # empty line scores all four missing anyway, so it never displaces the
        # initial value and removing the guard changes nothing here.
        printf '## Restrictions\n\n## Output Format\n\nNothing.\n' >"$sandbox2/emptysec.md"
        assert_equals "mktemp canonicalize unresolved provenance" \
            "$(agent_missing_clause_tokens "$sandbox2/emptysec.md" | command tr '\n' ' ' | command sed 's/ $//')" \
            "An empty Restrictions section reports the whole invariant, never passes by omission"

        command rm -rf "$sandbox2"
    else
        skip_test "mktemp -d unavailable — no-anchor case skipped"
    fi
}

# --- Run All Tests ----------------------------------------------------------

run_test test_agent_files_exist "Every agent has correctly named .md file"
run_test test_agent_frontmatter_fields "Every agent has required frontmatter fields"
run_test test_agent_model_values "Agent model values are valid (fable/opus/sonnet/haiku/inherit)"
run_test test_agent_tool_values "Agent tool values are from valid set"
run_test test_agent_tool_values_guard "Tool-value guard fires on invalid base, passes scoped Bash"
run_test test_skill_files_exist "Every skill has SKILL.md"
run_test test_skill_frontmatter "Every skill has description in frontmatter"
run_test test_skill_metadata_name_match "Skill metadata.yml name matches directory"
run_test test_check_skill_structure "check-* skills have 5-file structure"
run_test test_loop_skill_structure "loop-* skills have 5-file structure"
run_test test_context_skill_structure "context-* skills have 3-file structure"
run_test test_patterns_sh_executable "patterns.sh files are executable"
run_test test_bundled_shell_scripts_executable "every bundled .sh under plugins/ is executable (#604)"
run_test test_workflow_meta_pure_literal "Every workflow.js meta is a pure literal (no concat/interpolation)"
run_test test_workflow_js_node_check "Every workflow.js passes node --check (syntax valid)"
run_test test_workflow_js_node_check_detects_syntax_error "node --check guard fires on a syntax error"
run_test test_workflow_meta_guard_detects_violations "Meta pure-literal guard fires on the negative fixture"
run_test test_workflow_phase_meta_consistency "Every workflow.js phase() set matches meta.phases"
run_test test_workflow_phase_guard_detects_mismatch "Phase↔meta guard fires on the negative fixture"
run_test test_workflow_agenttype_resolves "Every workflow.js agentType is a resolvable <plugin>:<name>"
run_test test_workflow_agenttype_guard_detects_dangling "agentType guard fires on a namespaced-unresolvable ref"
run_test test_workflow_agenttype_guard_detects_bare "agentType guard fires on a bare (un-namespaced) ref"
# The live BUDGET_FLOOR sweep is retired — subsumed by
# tests/validate-prelude-sync.sh (#586); see the note above the extractor. The
# extractor-precision test stays: it covers this file's parsing helper, which the
# sync gate does not exercise.
run_test test_workflow_budget_floor_guard_detects_drift "BUDGET_FLOOR extractor is precise on the negative fixture"
run_test test_skill_required_tools_referenced "Every skill's required_tools are referenced in the skill"
run_test test_skill_required_tools_guard_detects_drift "required_tools reference guard fires on the negative fixture"
run_test test_agent_destructive_clause_present "Every agent's Restrictions carries the #426 destructive-shell clause"
run_test test_agent_destructive_clause_guard_detects_drift "Destructive-clause guard fires on the negative fixture, passes the reworded one"

generate_report
