#!/usr/bin/env bash
# check-ai-config — Deterministic Pre-Scan
#
# Validates Claude Code configuration files: agent/skill frontmatter,
# file bloat thresholds, config consistency, MCP settings, and hook safety.
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument)
#
# Note: Uses full paths for commands per project shell-scripting conventions.
set -euo pipefail

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# Thresholds (overridable via thresholds.yml in caller)
CLAUDE_MD_WARN=${CLAUDE_MD_WARN:-400}
CLAUDE_MD_HIGH=${CLAUDE_MD_HIGH:-600}
SKILL_WARN=${SKILL_WARN:-300}
SKILL_HIGH=${SKILL_HIGH:-500}
AGENT_WARN=${AGENT_WARN:-250}
AGENT_HIGH=${AGENT_HIGH:-400}
DOC_WARN=${DOC_WARN:-500}
DOC_HIGH=${DOC_HIGH:-800}

# =============================================================================
# Helper: extract YAML frontmatter value from a file
# Usage: get_frontmatter "file" "key"
# =============================================================================
get_frontmatter() {
    local file="$1" key="$2"
    /usr/bin/sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null |
        /usr/bin/grep -E "^${key}:" |
        /usr/bin/sed "s/^${key}:[[:space:]]*//" |
        /usr/bin/sed 's/^["'\'']//' | /usr/bin/sed 's/["'\'']\s*$//' |
        /usr/bin/head -1
}

# =============================================================================
# Category: agent-frontmatter
# Validates agent definition files for required fields and valid values.
# =============================================================================

check_agent_frontmatter() {
    local file="$1"

    # Only check agent .md files (dirname/dirname.md pattern)
    local basename dirname dirbase
    basename=$(/usr/bin/basename "$file")
    dirname=$(/usr/bin/dirname "$file")
    dirbase=$(/usr/bin/basename "$dirname")

    # Skip if not an agent definition file
    case "$file" in
        */agents/*/*.md) ;;
        *) return ;;
    esac

    # Check naming convention: agent file should match directory name
    local expected_name="${dirbase}.md"
    if [ "$basename" != "$expected_name" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Agent file should be named ${expected_name}, found ${basename}" "HIGH"
    fi

    # Check for frontmatter existence
    if ! /usr/bin/head -1 "$file" 2>/dev/null | /usr/bin/grep -q '^---$'; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing YAML frontmatter (no opening ---)" "HIGH"
        return
    fi

    # Check required fields
    local name desc tools model
    name=$(get_frontmatter "$file" "name")
    desc=$(get_frontmatter "$file" "description")
    tools=$(get_frontmatter "$file" "tools")
    model=$(get_frontmatter "$file" "model")

    if [ -z "$name" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: name" "HIGH"
    fi

    if [ -z "$desc" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: description" "HIGH"
    fi

    if [ -z "$tools" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: tools" "HIGH"
    fi

    if [ -z "$model" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: model" "HIGH"
    elif [ "$model" != "opus" ] && [ "$model" != "sonnet" ] && [ "$model" != "haiku" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Invalid model value: ${model} (expected opus, sonnet, or haiku)" "HIGH"
    fi

    # Check for wildcard tools
    if [ "$tools" = "*" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Agent uses wildcard tools (*) — scope to specific tools" "MEDIUM"
    fi
}

# =============================================================================
# Category: skill-frontmatter
# Validates skill definition files for required structure.
# =============================================================================

check_skill_frontmatter() {
    local file="$1"

    # Only check SKILL.md files in skills directories
    local basename dirname
    basename=$(/usr/bin/basename "$file")
    dirname=$(/usr/bin/dirname "$file")

    case "$file" in
        */skills/*/SKILL.md) ;;
        *) return ;;
    esac

    # Check for frontmatter with description
    if ! /usr/bin/head -1 "$file" 2>/dev/null | /usr/bin/grep -q '^---$'; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "Missing YAML frontmatter (no opening ---)" "HIGH"
        return
    fi

    local desc
    desc=$(get_frontmatter "$file" "description")
    if [ -z "$desc" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "Missing required frontmatter field: description" "HIGH"
    fi

    # Check for structural sections (workflow, categories, or conventions)
    # Reference-style skills use Categories/Conventions instead of Workflow
    if ! /usr/bin/grep -qE '^## (Workflow|Step|Phase|Categories|Conventions|Rules|Patterns|When to)' "$file" 2>/dev/null; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "No structural section found (expected ## Workflow, ## Categories, or similar)" "MEDIUM"
    fi

    # Check for missing metadata.yml
    if [ ! -f "${dirname}/metadata.yml" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "Missing metadata.yml in skill directory" "MEDIUM"
    fi
}

# =============================================================================
# Category: ai-file-bloat
# Checks AI instruction files against line count thresholds.
# =============================================================================

check_ai_file_bloat() {
    local file="$1"
    local basename lines threshold_warn threshold_high file_type

    basename=$(/usr/bin/basename "$file")
    lines=$(/usr/bin/wc -l <"$file" 2>/dev/null) || return
    lines=$((lines + 0)) # ensure numeric

    # Determine file type and thresholds
    case "$file" in
        */CLAUDE.md | */AGENTS.md)
            threshold_warn=$CLAUDE_MD_WARN
            threshold_high=$CLAUDE_MD_HIGH
            file_type="CLAUDE.md"
            ;;
        */skills/*/SKILL.md)
            threshold_warn=$SKILL_WARN
            threshold_high=$SKILL_HIGH
            file_type="skill definition"
            ;;
        */agents/*/*.md)
            threshold_warn=$AGENT_WARN
            threshold_high=$AGENT_HIGH
            file_type="agent definition"
            ;;
        */docs/*.md)
            threshold_warn=$DOC_WARN
            threshold_high=$DOC_HIGH
            file_type="documentation"
            ;;
        *) return ;;
    esac

    if [ "$lines" -gt "$threshold_high" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "ai-file-bloat" \
            "${file_type} exceeds high threshold: ${lines} lines (>${threshold_high})" "HIGH"
    elif [ "$lines" -gt "$threshold_warn" ]; then
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "ai-file-bloat" \
            "${file_type} exceeds warning threshold: ${lines} lines (>${threshold_warn})" "MEDIUM"
    fi
}

# =============================================================================
# Category: mcp-misconfiguration
# Checks MCP configuration for insecure patterns.
# =============================================================================

check_mcp_config() {
    local file="$1"

    # Only check JSON config files that might contain MCP settings
    case "$file" in
        *.json) ;;
        *) return ;;
    esac

    # Check for http:// URLs (except localhost exceptions)
    /usr/bin/grep -nE '"http://' "$file" 2>/dev/null |
        /usr/bin/grep -vE '(localhost|127\.0\.0\.1|host\.docker\.internal)' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "mcp-misconfiguration" \
                "Insecure HTTP URL in config (use HTTPS): ${evidence}" "HIGH"
        done || true
}

# =============================================================================
# Category: hook-safety
# Checks hook configurations for dangerous patterns.
# =============================================================================

check_hook_safety() {
    local file="$1"

    # Check JSON config files and shell scripts that could be hooks
    case "$file" in
        *.json | *.sh) ;;
        *) return ;;
    esac

    # Destructive commands without guards
    /usr/bin/grep -nE '(rm\s+-rf\s|git\s+reset\s+--hard|git\s+clean\s+-fd|docker\s+system\s+prune)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hook-safety" \
                "Destructive command in hook without confirmation: ${evidence}" "HIGH"
        done || true

    # Secret leaks — echoing env vars with secret-like names
    /usr/bin/grep -nE '(echo|printf).*\$(ANTHROPIC_|GITHUB_TOKEN|GITLAB_TOKEN|API_KEY|SECRET|PASSWORD|OP_.*_REF)' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hook-safety" \
                "Potential secret leak in hook output: ${evidence}" "HIGH"
        done || true
}

# =============================================================================
# Category: harness-logic
# Reviews workflow.js harnesses for the mechanical correctness/safety bug
# classes that frontmatter linting misses. Conservative by design — favors
# MEDIUM so the LLM pass (using the adversarial-review checklist) can confirm,
# avoiding the false-positive trap of aggressive HIGH greps.
# =============================================================================

check_harness_logic() {
    local file="$1"

    # Only workflow harness scripts (skip schemas, docs, etc.)
    case "$file" in
        *workflow.js) ;;
        *) return ;;
    esac

    # Non-unique finding ref: a "${a}:${b}:${c}" template (3 interpolations,
    # colon-joined) with no index segment (#). Collides when two findings share
    # file+line+category. A fixed ref carries a trailing #${i}.
    /usr/bin/grep -nE '`\$\{[^}]+\}:\$\{[^}]+\}:\$\{[^}]+\}`' "$file" 2>/dev/null |
        /usr/bin/grep -vE '#\$\{' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Finding ref may collide (no per-finding index): ${evidence}" "MEDIUM"
        done || true

    # Unsafe interpolation into an auto-approving command.
    /usr/bin/grep -nE 'dangerously-skip-permissions.*\$\{' "$file" 2>/dev/null |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Interpolation into --dangerously-skip-permissions (validate first): ${evidence}" "HIGH"
        done || true

    # Supply-chain regen: full install form without a lockfile-only/no-scripts flag.
    /usr/bin/grep -nE '(npm install|pnpm install|composer update|yarn install)' "$file" 2>/dev/null |
        /usr/bin/grep -vE 'package-lock-only|ignore-scripts|no-scripts|lockfile-only|update-lockfile' |
        while IFS=: read -r line_num content; do
            evidence=$(/usr/bin/printf '%.80s' "$content")
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Install/regen may run lifecycle scripts (use lockfile-only): ${evidence}" "MEDIUM"
        done || true

    # NOTE: the "silent drop of failed sub-results" bug class is intentionally
    # NOT pre-scanned here. A line-level grep for `.filter(Boolean)` cannot
    # distinguish a fan-out result (real bug if unlogged) from benign input-arg
    # sanitization, and the drop is often logged on a different line — so it
    # false-positives badly. It is left to the LLM pass via the
    # adversarial-review checklist, which can read the surrounding function.
}

# =============================================================================
# Main: iterate over file list, run all checks
# =============================================================================

while IFS= read -r file; do
    [ -f "$file" ] || continue

    check_agent_frontmatter "$file"
    check_skill_frontmatter "$file"
    check_ai_file_bloat "$file"
    check_mcp_config "$file"
    check_hook_safety "$file"
    check_harness_logic "$file"

done <"$FILE_LIST"
