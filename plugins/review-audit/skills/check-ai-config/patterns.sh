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
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- char-aware evidence truncation (#17 bash<->python equivalence) ----------
# Evidence is truncated to a fixed number of CHARACTERS to match the Python
# primary's str[:N]. `printf '%.Ns'` truncates by BYTES (and can split a UTF-8
# character), so multibyte evidence diverged between the two impls. Detect a
# UTF-8 locale once, then slice with bash parameter expansion under it
# (char-wise); fall back to the byte-wise printf if no UTF-8 locale exists.
_PRESCAN_UTF8_LOCALE=""
for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | command grep -qixF "$_cand"; then
        _PRESCAN_UTF8_LOCALE="$_cand"
        break
    fi
done
unset _cand
# truncate_chars <maxchars> <string> — first <maxchars> characters on stdout.
truncate_chars() {
    local n="$1" s="$2"
    if [ -n "$_PRESCAN_UTF8_LOCALE" ]; then
        local LC_CTYPE="$_PRESCAN_UTF8_LOCALE"
        printf '%s' "${s:0:$n}"
    else
        command printf "%.${n}s" "$s"
    fi
}

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
    # `grep` exits non-zero when the key is absent; guard it with `|| true` so a
    # no-match yields empty output with a zero pipeline status instead of tripping
    # `set -euo pipefail` and aborting the whole scan (#205). Mirrors the Python
    # primary, where an absent key returns "".
    command sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null |
        { command grep -E "^${key}:" || true; } |
        command sed "s/^${key}:[[:space:]]*//" |
        command sed 's/^["'\'']//' | command sed 's/["'\'']\s*$//' |
        command head -1
}

# =============================================================================
# Category: agent-frontmatter
# Validates agent definition files for required fields and valid values.
# =============================================================================

check_agent_frontmatter() {
    local file="$1"

    # Only check agent .md files (dirname/dirname.md pattern)
    local basename dirname dirbase
    basename=$(command basename "$file")
    dirname=$(command dirname "$file")
    dirbase=$(command basename "$dirname")

    # Skip if not an agent definition file
    case "$file" in
        */agents/*/*.md) ;;
        *) return ;;
    esac

    # Check naming convention: agent file should match directory name
    local expected_name="${dirbase}.md"
    if [ "$basename" != "$expected_name" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Agent file should be named ${expected_name}, found ${basename}" "HIGH"
    fi

    # Check for frontmatter existence
    if ! command head -1 "$file" 2>/dev/null | command grep -q '^---$'; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
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
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: name" "HIGH"
    fi

    if [ -z "$desc" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: description" "HIGH"
    fi

    if [ -z "$tools" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: tools" "HIGH"
    fi

    if [ -z "$model" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Missing required frontmatter field: model" "HIGH"
    elif [ "$model" != "fable" ] && [ "$model" != "opus" ] && [ "$model" != "sonnet" ] && [ "$model" != "haiku" ] && [ "$model" != "inherit" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "agent-frontmatter" \
            "Invalid model value: ${model} (expected fable, opus, sonnet, haiku, or inherit)" "HIGH"
    fi

    # Check for wildcard tools
    if [ "$tools" = "*" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
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
    basename=$(command basename "$file")
    dirname=$(command dirname "$file")

    case "$file" in
        */skills/*/SKILL.md) ;;
        *) return ;;
    esac

    # Check for frontmatter with description
    if ! command head -1 "$file" 2>/dev/null | command grep -q '^---$'; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "Missing YAML frontmatter (no opening ---)" "HIGH"
        return
    fi

    local desc
    desc=$(get_frontmatter "$file" "description")
    if [ -z "$desc" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "Missing required frontmatter field: description" "HIGH"
    fi

    # Check for structural sections (workflow, categories, or conventions)
    # Reference-style skills use Categories/Conventions instead of Workflow
    if ! command grep -qE '^## (Workflow|Step|Phase|Categories|Conventions|Rules|Patterns|When to)' "$file" 2>/dev/null; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "skill-frontmatter" \
            "No structural section found (expected ## Workflow, ## Categories, or similar)" "MEDIUM"
    fi

    # Check for missing metadata.yml
    if [ ! -f "${dirname}/metadata.yml" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
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
    local basename lines threshold_warn threshold_high file_type category

    basename=$(command basename "$file")
    lines=$(command wc -l <"$file" 2>/dev/null) || return
    lines=$((lines + 0)) # ensure numeric

    # `category` splits documentation bloat (docs/*.md) into its own
    # `doc-file-bloat` slug — the canonical name in finding-schema.md — while the
    # AI-instruction files (CLAUDE.md / SKILL.md / agent md) stay `ai-file-bloat`.
    category="ai-file-bloat"

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
        */agents/*/*.md | */agents/*.md)
            # Match BOTH the flat agents/<name>.md (Claude Code's discovery form)
            # and the nested agents/<name>/<name>.md a harness-bearing agent uses,
            # so a flat agent over the line threshold is not missed (#494). Mirrors
            # the patterns.py bloat branch exactly (bash<->python parity).
            threshold_warn=$AGENT_WARN
            threshold_high=$AGENT_HIGH
            file_type="agent definition"
            ;;
        */docs/*.md)
            threshold_warn=$DOC_WARN
            threshold_high=$DOC_HIGH
            file_type="documentation"
            category="doc-file-bloat"
            ;;
        *) return ;;
    esac

    if [ "$lines" -gt "$threshold_high" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "$category" \
            "${file_type} exceeds high threshold: ${lines} lines (>${threshold_high})" "HIGH"
    elif [ "$lines" -gt "$threshold_warn" ]; then
        command printf '%s\t%s\t%s\t%s\t%s\n' \
            "$file" "1" "$category" \
            "${file_type} exceeds warning threshold: ${lines} lines (>${threshold_warn})" "MEDIUM"
    fi
}

# =============================================================================
# Category: claude-md-drift
# CLAUDE.md / AGENTS.md referencing a relative file path that does not exist
# (resolved against the document's own directory, like check-docs-deadlinks).
# MEDIUM — the LLM pass separates literal drift from illustrative paths and
# verifies referenced *commands* (not checked here).
# =============================================================================

check_claude_md_drift() {
    local file="$1"

    case "$file" in
        */CLAUDE.md | */AGENTS.md) ;;
        *) return ;;
    esac

    local file_dir
    file_dir=$(command dirname "$file")

    # Backtick-quoted relative path with a source-file extension and >=1 `/`. The
    # char class [A-Za-z0-9_.-] excludes `$ { } * :`, so `${VAR}` templates,
    # globs, and `scheme://` URLs cannot match — the skip is built into the regex.
    command grep -noE '`[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.(sh|py|js|mjs|ts|json|ya?ml|md|toml)`' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            match=${raw#*:}
            target="${match#\`}"
            target="${target%\`}"
            if [ ! -e "${file_dir}/${target}" ]; then
                evidence=$(truncate_chars 80 "$target")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "claude-md-drift" \
                    "Referenced path not found: ${evidence}" "MEDIUM"
            fi
        done || true
}

# =============================================================================
# Category: config-inconsistency
# Skill/agent markdown citing a `<plugin>:<name>` agent or skill that does not
# exist. Only fires when `<plugins>/<plugin>/` is a real plugin dir but neither
# agents/<name>.md nor skills/<name>/SKILL.md resolves under it — so non-plugin
# `foo:bar` tokens (e.g. `go:generate`) are ignored. MEDIUM.
# =============================================================================

check_config_inconsistency() {
    local file="$1"

    case "$file" in
        */skills/*.md | */agents/*.md) ;;
        *) return ;;
    esac

    # The <root>/plugins dir this file lives under (first occurrence, mirroring
    # python's path.split("/plugins/")[0]).
    local plugins_dir
    case "$file" in
        */plugins/*) plugins_dir="${file%%/plugins/*}/plugins" ;;
        plugins/*) plugins_dir="plugins" ;;
        *) return ;;
    esac

    # Backtick-quoted `<plugin>:<name>` (lowercase kebab both sides). The match
    # itself carries a colon, so split the grep `line:match` prefix manually
    # rather than via IFS=:.
    command grep -noE '`[a-z0-9][a-z0-9-]*:[a-z0-9][a-z0-9-]*`' "$file" 2>/dev/null |
        while IFS= read -r row; do
            line_num="${row%%:*}"
            match="${row#*:}"
            token="${match#\`}"
            token="${token%\`}"
            plugin="${token%%:*}"
            name="${token##*:}"
            [ -d "${plugins_dir}/${plugin}" ] || continue
            if [ ! -f "${plugins_dir}/${plugin}/agents/${name}.md" ] &&
                [ ! -f "${plugins_dir}/${plugin}/skills/${name}/SKILL.md" ]; then
                evidence=$(truncate_chars 80 "${plugin}:${name}")
                command printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$file" "$line_num" "config-inconsistency" \
                    "Referenced agent/skill not found: ${evidence}" "MEDIUM"
            fi
        done || true
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
    command grep -nE '"http://' "$file" 2>/dev/null |
        command grep -vE '(localhost|127\.0\.0\.1|host\.docker\.internal)' |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
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
    command grep -nE '(rm\s+-rf\s|git\s+reset\s+--hard|git\s+clean\s+-fd|docker\s+system\s+prune)' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hook-safety" \
                "Destructive command in hook without confirmation: ${evidence}" "HIGH"
        done || true

    # Secret leaks — echoing env vars with secret-like names
    command grep -nE '(echo|printf).*\$(ANTHROPIC_|GITHUB_TOKEN|GITLAB_TOKEN|API_KEY|SECRET|PASSWORD|OP_.*_REF)' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
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
    command grep -nE '`\$\{[^}]+\}:\$\{[^}]+\}:\$\{[^}]+\}`' "$file" 2>/dev/null |
        command grep -vE '#\$\{' |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Finding ref may collide (no per-finding index): ${evidence}" "MEDIUM"
        done || true

    # Bare agentType — a subagent reference with no `<plugin>:` namespace. The
    # Workflow tool's agent() resolver keys agents ONLY by `<plugin>:<name>`
    # (the opposite of the Agent tool's bare subagent_type), so a bare name
    # throws at runtime and silently degrades the fan-out. Portable check: flag
    # any agentType literal lacking a colon. Cannot confirm the <plugin> half
    # resolves without this repo's layout, so MEDIUM for the LLM pass to confirm.
    command grep -nE "agentType:[[:space:]]*['\"][^'\":]+['\"]" "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Bare agentType (needs <plugin>:<name> for the Workflow tool): ${evidence}" "MEDIUM"
        done || true

    # Unsafe interpolation into an auto-approving command.
    command grep -nE 'dangerously-skip-permissions.*\$\{' "$file" 2>/dev/null |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Interpolation into --dangerously-skip-permissions (validate first): ${evidence}" "HIGH"
        done || true

    # Supply-chain regen: full install form without a lockfile-only/no-scripts flag.
    command grep -nE '(npm install|pnpm install|composer update|yarn install)' "$file" 2>/dev/null |
        command grep -vE 'package-lock-only|ignore-scripts|no-scripts|lockfile-only|update-lockfile' |
        while read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
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
    check_claude_md_drift "$file"
    check_config_inconsistency "$file"
    check_mcp_config "$file"
    check_hook_safety "$file"
    check_harness_logic "$file"

done <"$FILE_LIST"
