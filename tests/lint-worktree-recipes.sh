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
#
# THE COST OF THAT SCOPING, MEASURED RATHER THAN COUNTED BY HAND. Some inline
# directives genuinely instruct an invocation mid-sentence ("Resolve the
# disposition with `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh gate …`")
# and are invisible here even though they are instructions, not discussion.
#
# An earlier draft of this comment asserted "three exist today, all naming
# autonomy-resolve.sh". That was WRONG — workflow-wall-timeout.sh and
# recover-journal-partials.sh have inline directives too — and a hand-maintained
# census in prose is exactly the thing that rots into the same false-confidence
# note #815 exists to correct. So instead of a number, the gate MEASURES the
# inline population (test_inline_directive_census) and fails when it GROWS past
# a recorded baseline. Growth is the thing worth catching: a new inline
# directive is a new hand-applied site nobody was told about.
#
# Widening the fenced-block corpus to prose is still not the fix — it would flag
# the documentation of the rule itself, this header included.

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
# have to land as its own issue with its own respellings — filed as #819.
# Narrowing here is a STATED limitation, not an oversight: the gate covers the
# class the issue names and says plainly that it does not cover the neighbouring
# one. It is also the LOUD half of the class: a bare `$(...)` refusal is visible
# and stops the step, where the `eval` shape silently yields an empty string.
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
            # The marker must be FOLLOWED by a reason. A bare `worktree-safe-exempt:`
            # would otherwise be a blanket suppression with no stated argument —
            # exactly what the header says an exemption must never be.
            #
            # LEADING trim only, deliberately. The decision is "is anything left",
            # so a whitespace-ONLY remainder is emptied by the leading trim alone;
            # a remainder with any non-space character survives either way. A
            # trailing `[[:space:]]+$` alternation was written here first and a
            # mutation round proved it could not change the outcome for any input
            # — an unreachable branch, removed rather than covered by a test that
            # could never fail.
            if (index($0, marker) > 0) {
                rest = substr($0, index($0, marker) + length(marker))
                gsub(/^[[:space:]]+/, "", rest)
                if (length(rest) > 0) { exempt = 1 }
            }
            if ($0 ~ /\$\{CLAUDE_PLUGIN_ROOT\}/) { buf[++n] = f ":" NR ":${CLAUDE_PLUGIN_ROOT}" }
            else if ($0 ~ /\$CLAUDE_PLUGIN_ROOT/) { buf[++n] = f ":" NR ":$CLAUDE_PLUGIN_ROOT" }
            # `eval "$(...)"` ONLY — not a bare command substitution. See header.
            if ($0 ~ /eval[[:space:]]+"?\$\(/) { buf[++n] = f ":" NR ":eval command substitution" }
            if ($0 ~ /\$\{PWD\}/)     { buf[++n] = f ":" NR ":${PWD}" }
            else if ($0 ~ /\$PWD/)    { buf[++n] = f ":" NR ":$PWD" }
            # Braced ${HOME} and $USER are measured-refused too (the companion
            # table). Note the asymmetry that makes ${HOME} easy to miss:
            # UNBRACED "$HOME" is ALLOWED, so only the braced spelling is a
            # violation — which is why this is a distinct pattern and not a
            # HOME-anywhere match.
            if ($0 ~ /\$\{HOME\}/)    { buf[++n] = f ":" NR ":${HOME} (braced; bare $HOME is fine)" }
            if ($0 ~ /\$\{USER\}/ || $0 ~ /\$USER/) { buf[++n] = f ":" NR ":$USER" }
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
        "A quoted eval command substitution is flagged"

    # BRANCH COVERAGE. Each spelling pair below is a SEPARATE awk branch with its
    # own emitted message, so the fixtures above cover only one side of each. A
    # typo in an uncovered branch would ship silently.
    command cat >"$tmp/plugin-root-bare.md" <<'MD'
```bash
$CLAUDE_PLUGIN_ROOT/scripts/foo.sh check
```
MD
    assert_contains "$(scan_file "$tmp/plugin-root-bare.md")" 'CLAUDE_PLUGIN_ROOT' \
        "Unbraced \$CLAUDE_PLUGIN_ROOT is flagged (else-branch)"

    # The eval regex's `\"?` makes the quote OPTIONAL — untested until now.
    command cat >"$tmp/cmdsub-bare.md" <<'MD'
```bash
eval $(/literal/path/autonomy-resolve.sh level)
```
MD
    assert_contains "$(scan_file "$tmp/cmdsub-bare.md")" 'command substitution' \
        "An UNQUOTED eval command substitution is flagged (optional-quote branch)"

    command cat >"$tmp/pwd-braced.md" <<'MD'
```bash
/literal/path/context-budget.sh check "${PWD}"
```
MD
    assert_contains "$(scan_file "$tmp/pwd-braced.md")" 'PWD' \
        "Braced \${PWD} is flagged (if-branch)"

    # ```sh is accepted by the opener regex alongside ```bash.
    command cat >"$tmp/sh-fence.md" <<'MD'
```sh
${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh
```
MD
    assert_contains "$(scan_file "$tmp/sh-fence.md")" 'CLAUDE_PLUGIN_ROOT' \
        "A \`\`\`sh fence is in scope, same as \`\`\`bash"

    command cat >"$tmp/pwd.md" <<'MD'
```bash
/literal/path/context-budget.sh check "$PWD"
```
MD
    assert_contains "$(scan_file "$tmp/pwd.md")" 'PWD' \
        "\$PWD is flagged"

    command cat >"$tmp/home.md" <<'MD'
```bash
echo "${HOME}"
```
MD
    assert_contains "$(scan_file "$tmp/home.md")" 'HOME' \
        "Braced \${HOME} is flagged"

    command cat >"$tmp/user.md" <<'MD'
```bash
echo "$USER"
```
MD
    assert_contains "$(scan_file "$tmp/user.md")" 'USER' \
        "\$USER is flagged"
}

# The ${HOME} rule is the one most likely to be over-applied, because the
# UNBRACED spelling is measured ALLOWED. Pin the asymmetry explicitly: without
# this, widening the rule to a HOME-anywhere match would still pass every other
# test in the file.
test_unbraced_home_is_not_flagged() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    command cat >"$tmp/bare-home.md" <<'MD'
```bash
echo "$HOME/scripts/foo.sh"
```
MD
    assert_equals "" "$(scan_file "$tmp/bare-home.md")" \
        "Unbraced \$HOME is NOT flagged (measured allowed)"
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

# EXEMPTION SURFACE. A reason-required marker is a SOFT control: any
# plausible-sounding sentence satisfies it. This PR proved that risk is real
# rather than theoretical — a "detached-golem feed path, never worktree-isolated"
# exemption read perfectly and was measured FALSE in review, and it would have
# sat in the corpus permanently because an exemption is exactly what stops the
# gate looking.
#
# The fix is not to parse reasons (a regex cannot tell a true claim from a
# plausible one). It is to keep the exemption population SMALL and visible, so
# every addition is a diff a human weighs. A new exemption must move this number
# deliberately.
#
# Measured, not guessed — a first draft of this line said 6 and the test failed
# on 9, which is the same reflex (assert the number, skip the count) that this
# whole change exists to correct. Three of the nine are in worktree-safe-recipes.md
# itself, where the marker is being DOCUMENTED rather than used; the census
# cannot tell those apart, and a pattern that tried to would be the kind of
# cleverness that silently stops matching.
EXEMPTION_BUDGET=8

test_exemption_population_is_bounded() {
    local count
    count="$(command grep -rc 'worktree-safe-exempt:' \
        "$SKILLS_DIR"/next-issue "$SKILLS_DIR"/ship-issue "$SKILLS_DIR"/golem \
        --include='*.md' 2>/dev/null |
        command awk -F: '{s+=$2} END {print s+0}')"

    assert_true "[ \"$count\" -le $EXEMPTION_BUDGET ]" \
        "Exemptions have not grown past $EXEMPTION_BUDGET (found $count) — each one stops the gate looking, so a new one needs a deliberate budget bump and a reason a reviewer checked"
}

test_marker_requires_a_reason() {
    local tmp
    tmp="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    # A BARE marker grants no exemption — otherwise it is a blanket suppression
    # with no argument attached, which the header forbids.
    command cat >"$tmp/bare.md" <<'MD'
```bash
# worktree-safe-exempt:
${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh
```
MD
    assert_contains "$(scan_file "$tmp/bare.md")" 'CLAUDE_PLUGIN_ROOT' \
        "A bare marker with no reason does NOT exempt the block"

    # Whitespace after the colon is STILL bare — this pins the leading trim.
    # Built with printf, NOT a heredoc: trailing spaces in a heredoc are
    # invisible in the source and get stripped by editors and formatters, which
    # silently collapsed this fixture into a byte-identical copy of the bare case
    # above (caught in review). The two asserts below are what stop that
    # recurring — they fail if the fixture ever loses its whitespace.
    command printf '```bash\n# worktree-safe-exempt:   \t \n${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh\n```\n' \
        >"$tmp/spaces.md"
    assert_true "command grep -q 'exempt:   ' '$tmp/spaces.md'" \
        "The trailing-whitespace fixture really carries trailing whitespace"
    assert_true "! command cmp -s '$tmp/bare.md' '$tmp/spaces.md'" \
        "The whitespace fixture DIFFERS from the bare one (not a silent duplicate)"
    assert_contains "$(scan_file "$tmp/spaces.md")" 'CLAUDE_PLUGIN_ROOT' \
        "A marker followed only by whitespace does NOT exempt"

    command cat >"$tmp/reason.md" <<'MD'
```bash
# worktree-safe-exempt: runs pre-EnterWorktree from the main checkout
${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh
```
MD
    assert_equals "" "$(scan_file "$tmp/reason.md")" \
        "A marker WITH a reason exempts the block"
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

# CENSUS (see the header). The fenced-block corpus cannot see a mid-sentence
# `${CLAUDE_PLUGIN_ROOT}/…` directive, so those are hand-applied. This does not
# try to judge which mentions are directives versus discussion — that judgment
# is what a prose scanner cannot make, and pretending otherwise is how the last
# false census happened. It pins the POPULATION so the set cannot GROW
# unnoticed; shrinking is always fine.
#
# COUNTS EVERY SPELLING, not just the backtick-prefixed one. A first draft
# counted only `` `${CLAUDE_PLUGIN_ROOT} ``, which silently missed the quoted
# inline form ("${CLAUDE_PLUGIN_ROOT}/scripts/…") that appears in prose in these
# same files — a census narrower than its own description, which is the exact
# defect class this test was written to retire. Counting the bare token cannot
# have that gap.
#
# WHY A HAND-UPDATED BASELINE IS NOT JUST THE HAND-COUNT AGAIN. The number here
# is not a claim about the world that a reader must trust; it is a threshold the
# suite RE-DERIVES from the tree on every run. A stale baseline fails loudly
# instead of misinforming, which is precisely what the prose census could not do.
# Same contract as tests/prose-budget.baseline.
CENSUS_BASELINE=36
CENSUS_FLOOR=32

test_inline_directive_census() {
    local count
    count="$(command grep -c 'CLAUDE_PLUGIN_ROOT' \
        "$SKILLS_DIR"/next-issue/*.md \
        "$SKILLS_DIR"/ship-issue/*.md \
        "$SKILLS_DIR"/golem/*.md 2>/dev/null |
        command awk -F: '{s+=$2} END {print s+0}')"

    # A FLOOR AS WELL AS A CEILING. A `<=` ratchet alone cannot detect
    # UNDER-counting: narrowing the pattern just yields a smaller number, which
    # passes. Verified by mutation — narrowing the grep back to the
    # backtick-only spelling survived a ceiling-only check. The floor is what
    # makes a quietly-narrowed pattern fail instead of reading as progress.
    # Keep the window tight: a genuine cleanup should move BOTH bounds
    # deliberately, not slip under a loose floor.
    assert_true "[ \"$count\" -ge $CENSUS_FLOOR ]" \
        "The census still sees at least $CENSUS_FLOOR mentions (found $count) — a sudden drop means the PATTERN broke, not that the corpus improved; if the drop is real, lower the floor deliberately"
    assert_true "[ \"$count\" -le $CENSUS_BASELINE ]" \
        "\${CLAUDE_PLUGIN_ROOT} mentions have not grown past $CENSUS_BASELINE (found $count) — a new one may be a new hand-applied site; if intended, adjust the baseline deliberately"
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
run_test test_unbraced_home_is_not_flagged "Unbraced \$HOME stays allowed (braced/unbraced asymmetry)"
run_test test_exemption_marker_works "The exemption marker works and does not leak"
run_test test_marker_requires_a_reason "A bare marker with no reason grants no exemption"
run_test test_exemption_population_is_bounded "Exemptions stay within budget (each one blinds the gate)"
run_test test_marker_exempts_whole_block_not_one_line "The marker exempts per block, not per line"
run_test test_inline_directive_census "Inline \${CLAUDE_PLUGIN_ROOT} mentions have not grown"
run_test test_companion_documents_the_rule "The companion exists and documents the marker"
run_test test_claude_md_note_is_corrected "CLAUDE.md's false 'only one' claim is gone"

generate_report
