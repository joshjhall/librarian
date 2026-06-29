#!/usr/bin/env bash
# Shared agent-name resolver for cross-reference integrity gates (issue #41).
#
# Any artifact can name an agent by string — a SKILL.md `subagent_type:`
# frontmatter field, a workflow.js `agentType=` reference. Claude Code discovers
# plugin agents as FLAT markdown files at `plugins/<plugin>/agents/<name>.md`
# (see CLAUDE.md). This helper provides:
#
#   agent_resolver_index <plugins_dir>          — print every known agent name
#                                                  (basename of each flat
#                                                  agents/<name>.md), sorted
#   agent_resolver_exists <plugins_dir> <name>  — exit 0 if <name> resolves to a
#                                                  real flat agent file
#   collect_skill_subagent_types <plugins_dir>  — print every subagent_type value
#                                                  declared in any SKILL.md
#                                                  frontmatter, "<skill>\t<name>"
#                                                  per line
#
# Pure bash + coreutils; no node/jq. Sourced by validate-crossrefs.sh (and,
# later, by the workflow.js agentType check in the companion gate).

# Print every agent name known across all plugins, one per line, sorted unique.
# An agent name is the basename (sans .md) of a flat agents/<name>.md file.
agent_resolver_index() {
    local plugins_dir="$1"
    command find "$plugins_dir" -mindepth 3 -maxdepth 3 -type f -path '*/agents/*' \
        -name '*.md' 2>/dev/null |
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            /usr/bin/basename "$f" .md
        done | command sort -u
}

# Return 0 if <name> resolves to a flat agents/<name>.md file in any plugin.
agent_resolver_exists() {
    local plugins_dir="$1"
    local name="$2"
    [ -n "$name" ] || return 1
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -f "$f" ]; then
            return 0
        fi
    done < <(command find "$plugins_dir" -mindepth 3 -maxdepth 3 -type f \
        -path '*/agents/*' -name "${name}.md" 2>/dev/null)
    return 1
}

# Collect every subagent_type value declared in SKILL.md frontmatter across all
# plugins. Emits "<skill-path>\t<agent-name>" per reference, so the caller can
# report which skill carries a dangling reference.
#
# Supports two YAML shapes inside the `---`-fenced frontmatter block:
#   subagent_type: some-agent          (scalar)
#   subagent_type:                      (block list)
#     - some-agent
#     - other-agent
# and the inline-flow list form `subagent_type: [a, b]`. Values are stripped of
# surrounding quotes and whitespace; comments after a `#` are dropped.
collect_skill_subagent_types() {
    local plugins_dir="$1"
    local skill_file
    while IFS= read -r skill_file; do
        [ -n "$skill_file" ] || continue
        [ -f "$skill_file" ] || continue
        # Extract only the frontmatter block (first ---...--- fence).
        /usr/bin/awk '
            NR == 1 && $0 == "---" { infm = 1; next }
            infm && $0 == "---" { exit }
            infm { print }
        ' "$skill_file" |
            _emit_subagent_types_from_frontmatter "$skill_file"
    done < <(command find "$plugins_dir" -type f \
        -path '*/skills/*' -name 'SKILL.md' 2>/dev/null | command sort)
}

# Internal: read a frontmatter block on stdin, emit "<skill>\t<name>" lines.
_emit_subagent_types_from_frontmatter() {
    local skill_file="$1"
    /usr/bin/awk -v skill="$skill_file" '
        function strip(s) {
            sub(/#.*$/, "", s)                       # drop trailing comment
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/^["'"'"']|["'"'"']$/, "", s)        # strip wrapping quotes
            return s
        }
        function emit(v,   x) {
            x = strip(v)
            if (x != "" && x != "[]") print skill "\t" x
        }
        # Block-list continuation: "  - value" while inside a subagent_type key.
        inlist && /^[[:space:]]*-[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            emit(line)
            next
        }
        # Any other non-indented line ends a block list.
        inlist && /^[^[:space:]]/ { inlist = 0 }

        /^[[:space:]]*subagent_type[[:space:]]*:/ {
            val = $0
            sub(/^[[:space:]]*subagent_type[[:space:]]*:[[:space:]]*/, "", val)
            sub(/#.*$/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val == "") { inlist = 1; next }     # block list follows
            if (val ~ /^\[.*\]$/) {                 # inline flow list [a, b]
                gsub(/^\[|\]$/, "", val)
                n = split(val, parts, ",")
                for (i = 1; i <= n; i++) emit(parts[i])
                next
            }
            emit(val)                               # scalar
            next
        }
    '
}
