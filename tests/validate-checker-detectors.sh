#!/usr/bin/env bash
# check-ai-config detector behavioral gate (issue #204).
#
# The check-ai-config pre-scan (plugins/review-audit/skills/check-ai-config/)
# scans Claude Code CONFIG files — agent/skill frontmatter, CLAUDE.md bloat, MCP
# settings, hook safety, and workflow.js harness logic. Its detectors gate on
# path GLOBS (*/agents/*/*.md, */skills/*/SKILL.md, *.json, *.sh, *workflow.js),
# yet the shared parity/coverage corpus (validate-python-ports.sh,
# coverage-python.sh) contains NONE of those file types — so two-thirds of the
# scanner's branches never execute and had zero behavioral coverage.
#
# This gate is the behavioral half of that gap, modeled on
# validate-scanner-classification.sh: it drives PURPOSE-BUILT fixtures through the
# scanner and asserts the SPECIFIC finding category each fixture must emit — AND
# that a clean counter-fixture stays silent. Unlike validate-python-ports.sh
# (which only asserts bash==python PARITY, and so cannot catch a regression where
# both impls break the same way), this pins the actual detector output. Coverage
# rising 34% -> ~80%+ is a byproduct; the golden assertions are the deliverable.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# SKIPS (does not fail) when a python3>=3.11 is unavailable — the same posture as
# validate-python-ports.sh; the bash path is still asserted where present.
#
# Pure bash-3.2 + coreutils; full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$REPO_ROOT/plugins/review-audit/skills/check-ai-config"
PY="$SKILL_DIR/patterns.py"
SH="$SKILL_DIR/patterns.sh"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "check-ai-config detector fixtures (#204)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# --- Scanner drivers ---------------------------------------------------------
# run_py CAT LIST [ENV...] — python impl rows for one category. Extra args are
# VAR=VALUE env overrides (e.g. threshold tuning). Empty when python3 absent.
run_py() {
    local cat="$1" list="$2"
    shift 2
    [ "$HAVE_PY" -eq 1 ] || return 0
    /usr/bin/env "$@" python3 "$PY" "$list" 2>/dev/null |
        /usr/bin/awk -F '\t' -v c="$cat" '$3 == c'
}

# run_sh CAT LIST [ENV...] — bash fallback rows for one category (forced bash).
run_sh() {
    local cat="$1" list="$2"
    shift 2
    /usr/bin/env PATTERNS_FORCE_BASH=1 "$@" "$REAL_BASH" "$SH" "$list" 2>/dev/null |
        /usr/bin/awk -F '\t' -v c="$cat" '$3 == c'
}

# list_of PATH... — write a newline file list into WORKDIR, echo its path.
list_of() {
    local lf
    lf="$(/usr/bin/mktemp "$WORKDIR/list.XXXXXX")"
    /usr/bin/printf '%s\n' "$@" >"$lf"
    /usr/bin/printf '%s\n' "$lf"
}

# fresh_dir — unique scratch dir per fixture so path globs match cleanly.
fresh_dir() { /usr/bin/mktemp -d "$WORKDIR/case.XXXXXX"; }

# assert_fires CAT LIST NEEDLE MSG [ENV...] — the category fires (contains NEEDLE)
# in BOTH impls. Python side is skipped (not failed) when python3 is absent.
assert_fires() {
    local cat="$1" list="$2" needle="$3" msg="$4"
    shift 4
    local sh_rows py_rows
    sh_rows="$(run_sh "$cat" "$list" "$@")"
    assert_contains "$sh_rows" "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        py_rows="$(run_py "$cat" "$list" "$@")"
        assert_contains "$py_rows" "$needle" "$msg (python)"
    fi
}

# assert_silent CAT LIST MSG [ENV...] — the category emits NOTHING in both impls.
assert_silent() {
    local cat="$1" list="$2" msg="$3"
    shift 3
    local sh_rows py_rows
    sh_rows="$(run_sh "$cat" "$list" "$@")"
    assert_output_empty "$sh_rows" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        py_rows="$(run_py "$cat" "$list" "$@")"
        assert_output_empty "$py_rows" "$msg (python)"
    fi
}

# ============================================================================
# agent-frontmatter — */agents/<dir>/<dir>.md
# ============================================================================
test_agent_frontmatter() {
    local d f list
    d="$(fresh_dir)"

    # Wrong basename: agents/foo/bar.md (expected foo.md).
    /usr/bin/mkdir -p "$d/agents/foo"
    f="$d/agents/foo/bar.md"
    /usr/bin/printf '%s\n' "---" "name: x" "description: y" "tools: Read" "model: opus" "---" >"$f"
    list="$(list_of "$f")"
    assert_fires agent-frontmatter "$list" "should be named foo.md" \
        "agent-frontmatter: wrong basename flagged"

    # Missing opening frontmatter fence.
    /usr/bin/mkdir -p "$d/agents/nofm"
    f="$d/agents/nofm/nofm.md"
    /usr/bin/printf '%s\n' "# Just a heading" "no frontmatter here" >"$f"
    list="$(list_of "$f")"
    assert_fires agent-frontmatter "$list" "Missing YAML frontmatter" \
        "agent-frontmatter: missing opening --- flagged"

    # Present frontmatter missing all four required fields. Both impls now report
    # (bash's get_frontmatter no longer crashes on a missing field — #205 fixed).
    /usr/bin/mkdir -p "$d/agents/bare"
    f="$d/agents/bare/bare.md"
    /usr/bin/printf '%s\n' "---" "unrelated: value" "---" "body" >"$f"
    list="$(list_of "$f")"
    assert_fires agent-frontmatter "$list" "field: name" \
        "agent-frontmatter: missing name flagged"
    assert_fires agent-frontmatter "$list" "field: description" \
        "agent-frontmatter: missing description flagged"
    assert_fires agent-frontmatter "$list" "field: tools" \
        "agent-frontmatter: missing tools flagged"
    assert_fires agent-frontmatter "$list" "field: model" \
        "agent-frontmatter: missing model flagged"

    # Invalid model value.
    /usr/bin/mkdir -p "$d/agents/badmodel"
    f="$d/agents/badmodel/badmodel.md"
    /usr/bin/printf '%s\n' "---" "name: x" "description: y" "tools: Read" "model: gpt4" "---" >"$f"
    list="$(list_of "$f")"
    assert_fires agent-frontmatter "$list" "Invalid model value: gpt4" \
        "agent-frontmatter: invalid model flagged"

    # Wildcard tools (MEDIUM).
    /usr/bin/mkdir -p "$d/agents/wild"
    f="$d/agents/wild/wild.md"
    /usr/bin/printf '%s\n' "---" "name: x" "description: y" "tools: '*'" "model: opus" "---" >"$f"
    list="$(list_of "$f")"
    assert_fires agent-frontmatter "$list" "wildcard tools" \
        "agent-frontmatter: wildcard tools flagged"

    # Counter: a fully-valid agent file emits nothing.
    /usr/bin/mkdir -p "$d/agents/good"
    f="$d/agents/good/good.md"
    /usr/bin/printf '%s\n' "---" "name: good" "description: A well-formed agent." \
        "tools: Read, Grep" "model: sonnet" "---" "# Good" "body" >"$f"
    list="$(list_of "$f")"
    assert_silent agent-frontmatter "$list" \
        "agent-frontmatter: a valid agent file is silent"
}

# ============================================================================
# skill-frontmatter — */skills/<dir>/SKILL.md
# ============================================================================
test_skill_frontmatter() {
    local d f list

    # Missing description + no structural section + no metadata.yml. Both impls
    # now report all three rows — bash's get_frontmatter no longer crashes on the
    # missing `description` before reaching the section / metadata checks (#205).
    d="$(fresh_dir)"
    /usr/bin/mkdir -p "$d/skills/nodesc"
    f="$d/skills/nodesc/SKILL.md"
    /usr/bin/printf '%s\n' "---" "name: nodesc" "---" "Some prose with no section heading." >"$f"
    list="$(list_of "$f")"
    assert_fires skill-frontmatter "$list" "field: description" \
        "skill-frontmatter: missing description flagged"
    assert_fires skill-frontmatter "$list" "No structural section" \
        "skill-frontmatter: missing structural section flagged"
    assert_fires skill-frontmatter "$list" "Missing metadata.yml" \
        "skill-frontmatter: missing metadata.yml flagged"

    # Missing opening fence.
    d="$(fresh_dir)"
    /usr/bin/mkdir -p "$d/skills/nofm"
    f="$d/skills/nofm/SKILL.md"
    /usr/bin/printf '%s\n' "# No frontmatter" "body" >"$f"
    list="$(list_of "$f")"
    assert_fires skill-frontmatter "$list" "Missing YAML frontmatter" \
        "skill-frontmatter: missing opening --- flagged"

    # Counter: valid description + structural section + sibling metadata.yml.
    d="$(fresh_dir)"
    /usr/bin/mkdir -p "$d/skills/good"
    f="$d/skills/good/SKILL.md"
    /usr/bin/printf '%s\n' "---" "description: A well-formed skill." "---" \
        "## Workflow" "1. Do the thing." >"$f"
    /usr/bin/printf '%s\n' "name: good" >"$d/skills/good/metadata.yml"
    list="$(list_of "$f")"
    assert_silent skill-frontmatter "$list" \
        "skill-frontmatter: a valid skill (desc + section + metadata) is silent"
}

# ============================================================================
# ai-file-bloat — thresholds tuned down via env so a tiny fixture trips them.
# ============================================================================
test_ai_file_bloat() {
    local d f list
    d="$(fresh_dir)"

    # 5-line CLAUDE.md with HIGH driven to 3 -> exceeds high (HIGH).
    f="$d/CLAUDE.md"
    /usr/bin/printf '%s\n' "l1" "l2" "l3" "l4" "l5" >"$f"
    list="$(list_of "$f")"
    assert_fires ai-file-bloat "$list" "exceeds high threshold" \
        "ai-file-bloat: CLAUDE.md over high threshold flagged" \
        CLAUDE_MD_WARN=2 CLAUDE_MD_HIGH=3

    # Same file, WARN=3 HIGH=99 -> warning arm only (MEDIUM).
    assert_fires ai-file-bloat "$list" "exceeds warning threshold" \
        "ai-file-bloat: CLAUDE.md over warning threshold flagged" \
        CLAUDE_MD_WARN=3 CLAUDE_MD_HIGH=99

    # Counter: comfortably under both thresholds -> silent.
    assert_silent ai-file-bloat "$list" \
        "ai-file-bloat: CLAUDE.md under thresholds is silent" \
        CLAUDE_MD_WARN=50 CLAUDE_MD_HIGH=99

    # SKILL.md threshold arm (separate env family).
    /usr/bin/mkdir -p "$d/skills/big"
    f="$d/skills/big/SKILL.md"
    /usr/bin/printf '%s\n' "---" "description: d" "---" "## Workflow" "a" "b" "c" >"$f"
    /usr/bin/printf '%s\n' "name: big" >"$d/skills/big/metadata.yml"
    list="$(list_of "$f")"
    assert_fires ai-file-bloat "$list" "skill definition exceeds high threshold" \
        "ai-file-bloat: SKILL.md over high threshold flagged" \
        SKILL_WARN=2 SKILL_HIGH=3
}

# ============================================================================
# mcp-misconfiguration — *.json with insecure http:// (non-localhost)
# ============================================================================
test_mcp_config() {
    local d f list
    d="$(fresh_dir)"

    f="$d/mcp.json"
    /usr/bin/printf '%s\n' '{' '  "url": "http://evil.example.com/mcp"' '}' >"$f"
    list="$(list_of "$f")"
    assert_fires mcp-misconfiguration "$list" "Insecure HTTP URL" \
        "mcp-misconfiguration: external http:// flagged"

    # Counter: localhost / 127.0.0.1 http:// is allowlisted.
    f="$d/mcp-local.json"
    /usr/bin/printf '%s\n' '{' '  "a": "http://localhost:8080"' '  ,"b": "http://127.0.0.1:9000"' '}' >"$f"
    list="$(list_of "$f")"
    assert_silent mcp-misconfiguration "$list" \
        "mcp-misconfiguration: localhost/127.0.0.1 http:// is allowlisted"
}

# ============================================================================
# hook-safety — *.sh / *.json destructive commands + secret leaks
# ============================================================================
test_hook_safety() {
    local d f list
    d="$(fresh_dir)"

    f="$d/hook.sh"
    {
        /usr/bin/printf '%s\n' "#!/usr/bin/env bash"
        /usr/bin/printf '%s\n' "rm -rf /tmp/x"
        /usr/bin/printf '%s\n' "git reset --hard origin/main"
        # Secret-echo assembled so this test file holds no echo+token on one line.
        /usr/bin/printf 'echo %s\n' '$GITHUB_TOKEN'
    } >"$f"
    list="$(list_of "$f")"
    assert_fires hook-safety "$list" "Destructive command" \
        "hook-safety: destructive command flagged"
    assert_fires hook-safety "$list" "secret leak" \
        "hook-safety: secret echo flagged"

    # Counter: a benign hook line emits nothing.
    f="$d/benign.sh"
    /usr/bin/printf '%s\n' "#!/usr/bin/env bash" "echo hello" "ls -la" >"$f"
    list="$(list_of "$f")"
    assert_silent hook-safety "$list" \
        "hook-safety: a benign hook is silent"
}

# ============================================================================
# harness-logic — *workflow.js
# ============================================================================
test_harness_logic() {
    local d f list
    d="$(fresh_dir)"

    f="$d/workflow.js"
    {
        # ref-collision: three-part template ref with no per-finding #${...}.
        /usr/bin/printf '%s\n' 'const ref = `${domain}:${file}:${cat}`'
        # bare agentType (no <plugin>:<name> namespace).
        /usr/bin/printf "%s\n" "agentType: 'reviewer'"
        # unsafe interpolation into --dangerously-skip-permissions.
        /usr/bin/printf '%s\n' 'run(`claude --dangerously-skip-permissions ${task}`)'
        # install without a lockfile-only guard.
        /usr/bin/printf '%s\n' 'sh("npm install")'
    } >"$f"
    list="$(list_of "$f")"
    assert_fires harness-logic "$list" "ref may collide" \
        "harness-logic: colliding finding ref flagged"
    assert_fires harness-logic "$list" "Bare agentType" \
        "harness-logic: bare agentType flagged"
    assert_fires harness-logic "$list" "dangerously-skip-permissions" \
        "harness-logic: unsafe interpolation flagged"
    assert_fires harness-logic "$list" "lifecycle scripts" \
        "harness-logic: unguarded install flagged"

    # Counter: namespaced agentType + lockfile-only install + indexed ref.
    f="$d/safe.workflow.js"
    {
        /usr/bin/printf '%s\n' 'const ref = `${domain}:${file}:${cat}#${idx}`'
        /usr/bin/printf "%s\n" "agentType: 'review-audit:checker'"
        /usr/bin/printf '%s\n' 'sh("npm install --ignore-scripts")'
    } >"$f"
    list="$(list_of "$f")"
    assert_silent harness-logic "$list" \
        "harness-logic: namespaced agentType + lockfile-only install + indexed ref are silent"
}

# --- Drive -------------------------------------------------------------------
if [ "$HAVE_PY" -eq 0 ] && [ ! -f "$SH" ]; then
    skip_test "no python3>=3.11 and no patterns.sh — nothing to assert"
    generate_report
    return 0 2>/dev/null || exit 0
fi

run_test test_agent_frontmatter "agent-frontmatter: naming, fences, required fields, model, wildcard"
run_test test_skill_frontmatter "skill-frontmatter: description, structural section, metadata.yml"
run_test test_ai_file_bloat "ai-file-bloat: warn/high threshold arms (CLAUDE.md, SKILL.md)"
run_test test_mcp_config "mcp-misconfiguration: insecure http:// vs localhost allowlist"
run_test test_hook_safety "hook-safety: destructive commands + secret leaks vs benign"
run_test test_harness_logic "harness-logic: ref-collision, bare agentType, unsafe interp, install"

generate_report
