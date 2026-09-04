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

# --- input-shape guard (#816) -----------------------------------------------
# The file-list argument is a list of PATHS, one per line -- not a diff. Handed
# a diff, the scan loop reads each diff line as a path, matches nothing, emits
# nothing, and exits 0: an output indistinguishable from a genuinely clean scan.
# That is the #538/#571 failure (a gate that sits inert and reads as a pass)
# reached through the INPUT rather than the runtime, and it is easy to hit --
# both inputs come from adjacent `git diff` invocations differing only by
# `--name-only`, and both are plausibly named `*.diff`.
#
# Two checks, deliberately different in severity:
#
#   DIFF SHAPE -> hard failure (exit 1). Unambiguous: no file list contains a
#     `diff --git`/`@@`/`+++`/`--- ` line, so there is no legitimate input this
#     rejects, and the silent-zero scan is exactly what the caller must not get.
#
#   NOTHING RESOLVES -> stderr warning, exit code UNCHANGED. This one cannot be
#     an error: a list naming only deleted files is legitimate (the paths are
#     gone by design), and an EMPTY list exiting 0 in silence is a contract
#     tests/validate-prescans.sh pins for every pre-scan. So it is a warning
#     that catches stale lists and wrong-cwd invocations without breaking either
#     real case -- which is why it is guarded on a NON-EMPTY list.
#
# BASH_SOURCE[0], not $0: inside a function it names the file this function was
# DEFINED in, so the message stays correct under a symlink, a relative
# invocation from another cwd, or a `source` -- the same reasoning the SCRIPT_DIR
# computation elsewhere in these scanners uses.
# The multi-byte Unicode format characters the reflected line must not carry:
# the zero-width family (U+200B-200F), bidi overrides/embeddings (U+202A-202E),
# bidi isolates (U+2066-2069) and BOM (U+FEFF). A bidi override is the dangerous
# one: it makes the reflected text RENDER reversed, so a hostile path can display
# as something other than what it is.
#
# Built with printf as LITERAL UTF-8 bytes, not written as \xNN escapes -- those
# are a GNU sed extension that BSD sed reads as literal text, which is the silent
# #679 failure class (the pattern stops matching and nothing reports it).
# An ALTERNATION, not a bracket class: a bracket over multi-byte sequences
# matches byte-wise and can split a character.
#
# This is what keeps the bash fallback in step with _strip_control() in the
# python primary, whose isprintable() rejects category Cf for free. Without it
# the two runtimes diverge on exactly the path the fallback exists to serve
# (measured: RTLO survived in bash, was stripped in python).
_PRESCAN_BIDI_BYTES="$(command printf '\342\200\213|\342\200\214|\342\200\215|\342\200\216|\342\200\217|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\200\252|\342\200\253|\342\200\254|\342\200\255|\342\200\256|')"
_PRESCAN_BIDI_BYTES="${_PRESCAN_BIDI_BYTES}$(command printf '\342\201\246|\342\201\247|\342\201\250|\342\201\251|\357\273\277')"

assert_file_list_shape() {
    local list="$1"
    local tool="${BASH_SOURCE[0]##*/}"
    local line total=0 resolved=0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        total=$((total + 1))
        case "$line" in
            'diff --git '* | '--- '* | '+++ '* | '@@ '*)
                # STRIP CONTROL BYTES before echoing the line back. The input is
                # caller-supplied and may come from an untrusted diff; raw ESC/BEL
                # reaching the operator's terminal can move the cursor, hide
                # following output, or drive an OSC title-bar sequence. Keep tab
                # (\011) so indentation still reads. Measured: without this, a
                # crafted `diff --git \033[31m...\033]0;X\007` line renders as
                # live escapes rather than text.
                # Two passes, because one tool cannot do both portably.
                # (1) tr strips single-byte C0 controls + DEL (ESC, BEL, ...).
                #     Tab (\011) is kept so indentation still reads.
                # (2) sed strips the MULTI-BYTE Unicode format characters that
                #     tr cannot express: bidi overrides/isolates (U+202A-202E,
                #     U+2066-2069), the zero-width family (U+200B-200F) and BOM
                #     (U+FEFF). A bidi override is the dangerous one -- it makes
                #     the reflected path RENDER in reverse, so `evil.js` can be
                #     displayed as something else entirely. `tr -d '[:cntrl:]'`
                #     does NOT cover these (locale-dependent, and C0-only in the
                #     C locale, measured), which is why they are enumerated as
                #     literal UTF-8 byte sequences -- a spelling that behaves
                #     identically under BSD and GNU sed.
                #     This mirrors _strip_control() in the python primary, whose
                #     `isprintable()` rejects category Cf for free. Without pass
                #     (2) the two runtimes DIVERGE on exactly the fallback path
                #     the bash body exists to serve (verified: RTLO survived in
                #     bash and was stripped in python).
                _safe_line="$(command printf '%s' "$line" |
                    command tr -d '\000-\010\013-\037\177' |
                    command sed -E "s/(${_PRESCAN_BIDI_BYTES})//g")"
                echo "Error: ${tool}: input looks like a DIFF, not a file list: ${list}" >&2
                echo "  Offending line: ${_safe_line}" >&2
                echo "  Expected one path per line -- did you mean 'git diff --name-only'?" >&2
                echo "  Refusing to scan: a diff matches no path, so this would emit nothing and exit 0, which reads as a clean scan." >&2
                exit 1
                ;;
        esac
        if [ -e "$line" ]; then
            resolved=$((resolved + 1))
        fi
    done <"$list"

    if [ "$total" -gt 0 ] && [ "$resolved" -eq 0 ]; then
        echo "Warning: ${tool}: no path listed in ${list} exists (${total} non-empty lines); scanning nothing." >&2
        echo "  A stale list or a wrong working directory yields an empty scan that reads as clean. Findings below (if any) are from a partial view." >&2
    fi
}

assert_file_list_shape "$FILE_LIST"

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

# The per-file-type line thresholds (CLAUDE_MD_*, SKILL_*, AGENT_*, DOC_*) used
# to live here. They moved to check-decomposition/thresholds.yml together with
# the ai-file-bloat / doc-file-bloat categories (issue #663) so exactly one tool
# counts lines — ADR-0001 § 3 calls two scanners emitting a line-limit finding
# at line 1 of the same file with different numbers the failure mode to avoid.
# The variable NAMES are unchanged there, so an operator override keeps working.

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
        command sed 's/^["'\'']//' | command sed 's/["'\''][[:space:]]*$//' |
        command head -1
}

# =============================================================================
# Category: agent-frontmatter
# Validates agent definition files for required fields and valid values.
# =============================================================================

check_agent_frontmatter() {
    local file="$1"

    # Only check agent .md files — BOTH layouts (#525)
    local basename dirname dirbase nested
    basename=$(command basename "$file")
    dirname=$(command dirname "$file")
    dirbase=$(command basename "$dirname")

    # Skip if not an agent definition file. Claude Code discovers PLUGIN agents
    # only as flat `agents/<name>.md`; the nested `agents/<name>/<name>.md` form
    # appears in project-local `.claude/agents/`. Gating on the nested glob alone
    # — as this did — meant the layout this repo mandates got NO frontmatter
    # validation at all, the same blind spot #494 fixed for the bloat detector.
    nested=0
    case "$file" in
        */agents/*/*.md) nested=1 ;;
        */agents/*.md) ;;
        *) return ;;
    esac

    # Check naming convention: agent file should match directory name.
    # NESTED ONLY — the convention is "the file matches its own directory", which
    # is meaningless for a flat agent whose parent dir is always `agents/`.
    # Applying it there would demand `agents.md` and flag every correctly-named
    # flat agent, turning a widened detector into a false-positive generator.
    if [ "$nested" -eq 1 ]; then
        local expected_name="${dirbase}.md"
        if [ "$basename" != "$expected_name" ]; then
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "1" "agent-frontmatter" \
                "Agent file should be named ${expected_name}, found ${basename}" "HIGH"
        fi
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
        while IFS= read -r raw; do
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
        while IFS= read -r raw; do
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
    command grep -nE '(rm[[:space:]]+-rf[[:space:]]|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-fd|docker[[:space:]]+system[[:space:]]+prune)' "$file" 2>/dev/null |
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "hook-safety" \
                "Destructive command in hook without confirmation: ${evidence}" "HIGH"
        done || true

    # Secret leaks — echoing env vars with secret-like names
    command grep -nE '(echo|printf).*\$(ANTHROPIC_|GITHUB_TOKEN|GITLAB_TOKEN|API_KEY|SECRET|PASSWORD|OP_.*_REF)' "$file" 2>/dev/null |
        while IFS= read -r raw; do
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
        while IFS= read -r raw; do
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
        while IFS= read -r raw; do
            line_num=${raw%%:*}
            content=${raw#*:}
            evidence=$(truncate_chars 80 "$content")
            command printf '%s\t%s\t%s\t%s\t%s\n' \
                "$file" "$line_num" "harness-logic" \
                "Bare agentType (needs <plugin>:<name> for the Workflow tool): ${evidence}" "MEDIUM"
        done || true

    # Unsafe interpolation into an auto-approving command.
    command grep -nE 'dangerously-skip-permissions.*\$\{' "$file" 2>/dev/null |
        while IFS= read -r raw; do
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
        while IFS= read -r raw; do
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
    check_claude_md_drift "$file"
    check_config_inconsistency "$file"
    check_mcp_config "$file"
    check_hook_safety "$file"
    check_harness_logic "$file"

done <"$FILE_LIST"
