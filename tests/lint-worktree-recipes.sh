#!/usr/bin/env bash
# Worktree-safe recipe gate (issue #815).
#
# The Claude Code Bash tool REFUSES a command it cannot statically verify stays
# in-tree, once the session is `EnterWorktree`-isolated. #809 discovered this,
# fixed ONE recipe (golem/SKILL.md § Phase C), and then recorded in CLAUDE.md
# that it was "the only recipe that runs post-EnterWorktree". That was false:
# Phase C delegates to /workflow:next-issue, which chains /workflow:ship-issue
# in-turn at L3-L4, so every recipe those two skills execute is isolated too.
# This gate is what stops the class recurring — and, unlike a prose note, it
# cannot quietly go stale.
#
# WHY IT MATTERS MOST FOR `eval "$(...)"`. A refused command substitution yields
# an EMPTY STRING, so `eval "$(autonomy-resolve.sh level …)"` leaves
# autonomy_level unset and the run silently falls back to L1 — an L4 golem starts
# gating on prompts nobody is watching. That is the shape this gate weights
# heaviest, and the one #815 removed from all three resolver call sites.
#
# WHITELIST OF SKILLS, NOT A BLANKET SCAN. Only the three skills that can run
# worktree-isolated are walked: next-issue/, ship-issue/, golem/. The
# detached-golem feed recipes (golem-status.sh, golem-attach.sh, golem-inbox.sh,
# golem-notify.sh) keep their ${CLAUDE_PLUGIN_ROOT} spelling on purpose — a
# tmux/container golem sets cwd via `tmux new-session -c` at launch and is never
# EnterWorktree-isolated. Those live in escalation-protocol.md and in
# ci-review-protocol.md's notify blocks.
#
# Scoping by ROOT rather than by a `grep -v` filter is deliberate, and mirrors
# lint-command-refs.sh's rationale: an exclusion expressed as a filter is a line
# someone can delete, while an exclusion expressed as a corpus boundary cannot
# regress silently. But note the difference from that gate — here the excluded
# recipes live INSIDE walked files, so the boundary alone cannot carry them.
# That is what EXEMPT_MARKER is for: an explicit, reasoned, per-block opt-out.
#
# FENCED ```bash BLOCKS ONLY — never inline code, never prose. A recipe is what
# an agent EXECUTES; prose that merely mentions `${CLAUDE_PLUGIN_ROOT}` (the
# CLAUDE.md convention statement, the companion's own matrix, this header) is
# discussion, not instruction. Gating prose would make the documentation of the
# rule violate the rule — the same self-contradiction lint-command-refs.sh
# avoids by exempting docs/verification/**.

set -euo pipefail

SCRIPT_DIR="$(command cd "$(command dirname "${BASH_SOURCE[0]}")" && command pwd)"
REPO_ROOT="$(command cd "$SCRIPT_DIR/.." && command pwd)"

# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"

test_suite "Worktree-safe recipes (#815)"

# --- Corpus ------------------------------------------------------------------

# The three skills that can run while EnterWorktree-isolated. Explicit and
# ordered — never a glob over skills/ — so adding a skill to the isolated set is
# a deliberate edit here, the same contract tests/lib/fragments.sh uses.
WORKTREE_SKILLS="next-issue
ship-issue
golem"

# A block carrying this marker is exempt. It takes a reason on the same line;
# a bare marker is rejected by test_marker_requires_a_reason.
EXEMPT_MARKER='worktree-safe-exempt:'

# WHAT THIS GATE FLAGS, AND WHAT IT DELIBERATELY DOES NOT.
#
# Flagged: `${CLAUDE_PLUGIN_ROOT}` / `$CLAUDE_PLUGIN_ROOT` (the bundled-script
# path spelling #815 is about), `$PWD`, and the `eval "$(...)"` shape
# specifically (AC4's silent-empty-string failure).
#
# NOT flagged: a bare command substitution. That is a real refusal — measured —
# but banning `$(` outright would flag ~25 legitimate recipes across these
# skills (git plumbing in execute-protocol.md, gh queries in
# dependency-queue.md), which is a far wider sweep than #815 scopes and would
# have to land as its own issue with its own respellings. Narrowing here is a
# STATED limitation, not an oversight: the gate covers the class the issue
# names and says plainly that it does not cover the neighbouring one.
#
# Also NOT flagged: an inline-assigned variable (`cycle=1; script --arg
# "$cycle"`) or an unbraced `$HOME` — both measured ALLOWED, so a blanket `\$`
# ban would reject the very forms the companion recommends.

# collect_recipe_files — every markdown file in the three isolated skills.
collect_recipe_files() {
    local skills_dir="$1" skill
    while IFS= read -r skill; do
        [ -n "$skill" ] || continue
        [ -d "$skills_dir/$skill" ] || {
            command printf 'lint-worktree-recipes: missing skill dir %s\n' \
                "$skills_dir/$skill" >&2
            return 1
        }
        command find "$skills_dir/$skill" -type f -name '*.md' 2>/dev/null
    done <<EOF
$WORKTREE_SKILLS
EOF
}

# scan_file <file> — emit "<file>:<line>:<pattern>" for each refused spelling
# inside a fenced ```bash block that carries no exemption marker.
#
# ONE pass with an in-fence state flag, and the exemption is decided PER BLOCK
# rather than per line: a marker anywhere in the block exempts the whole block,
# because the marker is a statement about the recipe, not about one of its
# lines. That requires buffering the block before judging it — which is why this
# collects lines and flushes at the closing fence rather than reporting inline.
scan_file() {
    local file="$1"
    command awk -v f="$file" -v marker="$EXEMPT_MARKER" '
        BEGIN { infence = 0; exempt = 0; n = 0 }
        # Opening fence: ```bash or ```sh (optionally with attributes).
        !infence && /^[[:space:]]*```[[:space:]]*(bash|sh)([[:space:]]|$)/ {
            infence = 1; exempt = 0; n = 0; next
        }
        infence && /^[[:space:]]*```[[:space:]]*$/ {
            if (!exempt) { for (i = 1; i <= n; i++) print buf[i] }
            infence = 0; n = 0; next
        }
        infence {
            if (index($0, marker) > 0) { exempt = 1 }
            if ($0 ~ /\$\{CLAUDE_PLUGIN_ROOT\}/) { buf[++n] = f ":" NR ":${CLAUDE_PLUGIN_ROOT}" }
            else if ($0 ~ /\$CLAUDE_PLUGIN_ROOT/) { buf[++n] = f ":" NR ":$CLAUDE_PLUGIN_ROOT" }
            # `eval "$(...)"` ONLY — not a bare command substitution. See header.
            if ($0 ~ /eval[[:space:]]+"?\$\(/) { buf[++n] = f ":" NR ":eval command substitution" }
            if ($0 ~ /\$\{PWD\}/)     { buf[++n] = f ":" NR ":${PWD}" }
            else if ($0 ~ /\$PWD/)    { buf[++n] = f ":" NR ":$PWD" }
        }
    ' "$file"
}

# scan_all <skills_dir> — every violation across the corpus.
scan_all() {
    local skills_dir="$1" file
    local files
    files="$(collect_recipe_files "$skills_dir")" || return 1
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        scan_file "$file"
    done <<EOF
$files
EOF
}

# --- Tests -------------------------------------------------------------------

SKILLS_DIR="$REPO_ROOT/plugins/workflow/skills"

test_corpus_is_not_vacuous() {
    local files count
    files="$(collect_recipe_files "$SKILLS_DIR")"
    count="$(command printf '%s\n' "$files" | command grep -c . || true)"
    assert_true "[ \"$count\" -ge 10 ]" \
        "The corpus collects real markdown across the three isolated skills (got $count)"
}

test_every_isolated_skill_is_present() {
    local skill
    while IFS= read -r skill; do
        [ -n "$skill" ] || continue
        assert_file_exists "$SKILLS_DIR/$skill/SKILL.md" \
            "Isolated skill '$skill' exists and is walked"
    done <<EOF
$WORKTREE_SKILLS
EOF
}

test_no_refused_recipes() {
    local violations
    violations="$(scan_all "$SKILLS_DIR" || true)"
    if [ -n "$violations" ]; then
        command printf 'Refused spellings in worktree-isolated recipes:\n%s\n' \
            "$violations" >&2
    fi
    assert_true "[ -z \"$violations\" ]" \
        "No fenced recipe in next-issue/ship-issue/golem carries a refused spelling"
}

test_no_eval_command_substitution() {
    local hits
    hits="$(scan_all "$SKILLS_DIR" 2>/dev/null | command grep 'eval command substitution' || true)"
    assert_true "[ -z \"$hits\" ]" \
        "No recipe wraps a helper in eval \"\$(...)\" — the silent-empty-string shape (#815 AC4)"
}

# TEETH. The three tests above are absence assertions: if scan_file broke and
# returned nothing, all three would pass. These plant known-bad fixtures and
# require a hit, so a neutered scanner fails here (absence-assertion-needs-a-leak
# -fixture).
test_scanner_detects_each_refused_pattern() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/plugin-root.md" <<'MD'
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh check
```
MD
    assert_contains "$(scan_file "$tmp/plugin-root.md")" 'CLAUDE_PLUGIN_ROOT' \
        "Braced \${CLAUDE_PLUGIN_ROOT} in a bash fence is flagged"

    command cat >"$tmp/cmdsub.md" <<'MD'
```bash
eval "$(/literal/path/autonomy-resolve.sh level)"
```
MD
    assert_contains "$(scan_file "$tmp/cmdsub.md")" 'command substitution' \
        "A command substitution is flagged"

    command cat >"$tmp/pwd.md" <<'MD'
```bash
/literal/path/context-budget.sh check "$PWD"
```
MD
    assert_contains "$(scan_file "$tmp/pwd.md")" 'PWD' \
        "\$PWD is flagged"
}

# NARROWNESS. A gate that flags everything is as useless as one that flags
# nothing. These pin that the SAFE spellings the companion recommends are not
# flagged — otherwise the fix #815 shipped would itself fail the gate.
test_scanner_passes_the_safe_spellings() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/safe.md" <<'MD'
```bash
<skill-base-dir>/../../scripts/autonomy-resolve.sh level --chosen-level 3
```
MD
    assert_equals "" "$(scan_file "$tmp/safe.md")" \
        "The <skill-base-dir> literal form passes"

    command cat >"$tmp/inline.md" <<'MD'
```bash
cycle=1
/literal/path/review-convergence.sh check --cycle "$cycle"
```
MD
    assert_equals "" "$(scan_file "$tmp/inline.md")" \
        "An inline-assigned variable passes (measured allowed; not a \$ ban)"

    command cat >"$tmp/prose.md" <<'MD'
Call it via `${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh` from the main checkout.

```text
${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh
```
MD
    assert_equals "" "$(scan_file "$tmp/prose.md")" \
        "Inline code and non-bash fences are out of scope (prose is not a recipe)"
}

test_exemption_marker_works() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/exempt.md" <<'MD'
```bash
# worktree-safe-exempt: detached-golem feed, never EnterWorktree-isolated
${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh
```
MD
    assert_equals "" "$(scan_file "$tmp/exempt.md")" \
        "A marked block is exempt"

    # The marker must not leak past its own block.
    command cat >"$tmp/leak.md" <<'MD'
```bash
# worktree-safe-exempt: this block only
${CLAUDE_PLUGIN_ROOT}/scripts/golem-status.sh
```

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh level
```
MD
    assert_contains "$(scan_file "$tmp/leak.md")" 'CLAUDE_PLUGIN_ROOT' \
        "The exemption does NOT leak into the next block"
}

test_marker_exempts_whole_block_not_one_line() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    # The marker sits AFTER the offending line. A per-line implementation would
    # flag line 2; a per-block one exempts it. Pin the per-block semantics.
    command cat >"$tmp/after.md" <<'MD'
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/golem-notify.sh
# worktree-safe-exempt: feed path
```
MD
    assert_equals "" "$(scan_file "$tmp/after.md")" \
        "A marker anywhere in the block exempts the whole block"
}

test_companion_documents_the_rule() {
    local companion="$SKILLS_DIR/next-issue/worktree-safe-recipes.md"
    assert_file_exists "$companion" "The companion the gate points readers at exists"
    assert_file_contains "$companion" "worktree-safe-exempt" \
        "The companion documents the exemption marker this gate honors"
}

test_claude_md_note_is_corrected() {
    local claude_md="$REPO_ROOT/CLAUDE.md"
    assert_file_not_contains "$claude_md" "only recipe that runs post-" \
        "CLAUDE.md no longer claims Phase C is the only affected recipe (#815 AC1)"
    assert_file_contains "$claude_md" "worktree-safe-recipes.md" \
        "CLAUDE.md points at the companion instead of restating the rule"
}

run_test test_corpus_is_not_vacuous "The recipe corpus is non-empty"
run_test test_every_isolated_skill_is_present "Every whitelisted isolated skill exists"
run_test test_no_refused_recipes "No isolated recipe carries a refused spelling"
run_test test_no_eval_command_substitution "No recipe uses the silent eval \"\$(...)\" shape"
run_test test_scanner_detects_each_refused_pattern "The scanner fires on each refused pattern"
run_test test_scanner_passes_the_safe_spellings "The scanner passes the safe spellings"
run_test test_exemption_marker_works "The exemption marker works and does not leak"
run_test test_marker_exempts_whole_block_not_one_line "The marker exempts per block, not per line"
run_test test_companion_documents_the_rule "The companion exists and documents the marker"
run_test test_claude_md_note_is_corrected "CLAUDE.md's false 'only one' claim is gone"

generate_report
