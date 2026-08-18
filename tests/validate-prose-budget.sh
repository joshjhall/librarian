#!/usr/bin/env bash
# Behavioral gate for tests/lint-prose-budget.sh (issue #589, AC5).
#
# The negative fixture proving the prose-budget gate actually fires. A size gate
# is unusually easy to ship inert: it walks a corpus, finds nothing over budget,
# exits 0 — and a version with the comparison deleted does exactly the same
# thing on a clean tree. So every rule below is driven against a SANDBOX corpus
# with planted sizes rather than against the real tree, where the only observable
# outcome is "green".
#
# THE CENTRAL PROPERTY is the RATCHET, and it takes three cases to pin, not one:
#
#   over budget, no baseline entry   -> FAIL   (a new file gets its real budget)
#   over budget, exactly at baseline -> pass   (today's tree lands green)
#   baseline + 1                     -> FAIL   (growth is what this catches)
#
# The middle case is what makes the other two meaningful. A gate that failed on
# all three would be "budget only" and could never land green; one that passed
# all three would be inert. Only the pair (at-baseline passes, +1 fails) shows
# the ceiling is max(budget, baseline) rather than either alone.
#
# WHY A SANDBOX CORPUS. lint-prose-budget.sh takes its root, thresholds file and
# baseline path from PROSE_BUDGET_* env vars precisely so this suite can point it
# at planted trees. Asserting against the real repo would make every case
# hostage to unrelated prose edits — the fixture would decay into "whatever the
# tree happens to be today", which is how a gate stops testing anything.
#
# MUTATION-VERIFIED (the #221/#663 precedent; the
# mutation-round-finds-the-untested-rule lesson). Each RULE was broken
# transiently and this suite confirmed red, then reverted:
#   ratchet     — `ceiling=$budget` never raised to baseline   -> red (at-baseline case)
#   ratchet     — ceiling forced to baseline, ignoring budget  -> red (no-entry case)
#   companion   — */skills/*/*.md arm deleted from classify()  -> red (classification case)
#   ordering    — companion arm hoisted above SKILL.md         -> red (SKILL.md budget case)
#   corpus root — PLUGINS_DIR widened to $REPO_ROOT            -> red (verification-exempt case)
#   fail-loud   — missing-threshold path defaulted instead of exiting -> red
#
# THE ROUND PAID FOR ITSELF: the ordering mutation initially SURVIVED. The
# original SKILL.md case planted a 450-line file, which is over the 300 warning
# but under BOTH the 500 skill budget and the 650 companion budget — so it passed
# either way, exactly the anchored-regex-tautological-test shape. The fixture is
# now 520 lines, between the two budgets, which is the only band where the
# ordering is observable at all.
#
# Pure bash + coreutils. Full command paths per project convention.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

GATE="$SCRIPT_DIR/lint-prose-budget.sh"
REAL_THRESHOLDS="$REPO_ROOT/plugins/review-audit/skills/check-decomposition/thresholds.yml"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "prose-budget ratchet gate (#589)"

# --- Fixture helpers ---------------------------------------------------------

# make_md PATH NLINES — a markdown file of exactly NLINES lines.
make_md() {
    local path="$1" n="$2" i=1
    command mkdir -p "$(command dirname "$path")"
    : >"$path"
    while [ "$i" -le "$n" ]; do
        command printf 'line %d of prose\n' "$i" >>"$path"
        i=$((i + 1))
    done
}

# run_gate SANDBOX_PLUGINS BASELINE [ARGS...] — run the gate against a planted
# corpus, capturing output and exit code into GATE_OUT / GATE_RC.
#
# NOT a command substitution: an assertion inside a $() subshell cannot flip the
# parent's TEST_STATUS, which silently makes the check inert. That exact defect
# was found and fixed in validate-sizing-scanner.sh; this splits run-from-assert
# for the same reason.
GATE_OUT=""
GATE_RC=0
run_gate() {
    local plugins="$1" baseline="$2"
    shift 2
    GATE_OUT="$(
        PROSE_BUDGET_PLUGINS_DIR="$plugins" \
            PROSE_BUDGET_BASELINE="$baseline" \
            PROSE_BUDGET_THRESHOLDS="$REAL_THRESHOLDS" \
            command bash "$GATE" "$@" 2>&1
    )"
    GATE_RC=$?
    return 0
}

# --- The ratchet: three cases ------------------------------------------------

# An agent file at 500 lines is over the 400 agent_md budget. With no baseline
# entry it must FAIL — a newly-added oversized file gets its real budget, not
# the loosest number in the repo.
test_over_budget_no_baseline_fails() {
    local sb="$WORKDIR/case1"
    make_md "$sb/plugins/p/agents/big.md" 500
    run_gate "$sb/plugins" "$WORKDIR/case1.baseline"

    assert_exit 1 "$GATE_RC" "Over-budget file with no baseline entry must fail"
    assert_contains "$GATE_OUT" "no baseline entry" \
        "Failure names the missing baseline entry"
    assert_contains "$GATE_OUT" "agents/big.md" \
        "Failure names the offending file"
}

# The same file, recorded in the baseline at its exact size, must PASS. This is
# what lets the gate land green on a tree that already exceeds its budgets.
test_at_baseline_passes() {
    local sb="$WORKDIR/case2" bl="$WORKDIR/case2.baseline"
    make_md "$sb/plugins/p/agents/big.md" 500
    command printf 'plugins/p/agents/big.md 500\n' >"$bl"
    # The baseline stores repo-relative paths; a sandbox outside the repo root
    # keeps its absolute path, so plant BOTH spellings to stay location-agnostic.
    command printf '%s/plugins/p/agents/big.md 500\n' "$sb" >>"$bl"
    run_gate "$sb/plugins" "$bl"

    assert_exit 0 "$GATE_RC" "A file at its baseline entry must pass (green on today's tree)"
}

# One line above the baseline must FAIL. THE central property — this is the only
# case that distinguishes a working ratchet from a frozen allowlist.
test_baseline_plus_one_fails() {
    local sb="$WORKDIR/case3" bl="$WORKDIR/case3.baseline"
    make_md "$sb/plugins/p/agents/big.md" 501
    command printf 'plugins/p/agents/big.md 500\n' >"$bl"
    command printf '%s/plugins/p/agents/big.md 500\n' "$sb" >>"$bl"
    run_gate "$sb/plugins" "$bl"

    assert_exit 1 "$GATE_RC" "One line above the baseline must fail (growth is the point)"
    assert_contains "$GATE_OUT" "501" "Failure reports the actual size"
    assert_contains "$GATE_OUT" "500" "Failure reports the baseline it exceeded"
}

# Shrinking below the baseline passes, and --regen TIGHTENS the entry rather
# than leaving the old looser number. Without this the ratchet only ever
# loosens, which is a permanent allowlist wearing a ratchet's name.
test_regen_tightens() {
    local sb="$WORKDIR/case4" bl="$WORKDIR/case4.baseline"
    make_md "$sb/plugins/p/agents/big.md" 450
    command printf 'plugins/p/agents/big.md 500\n' >"$bl"
    command printf '%s/plugins/p/agents/big.md 500\n' "$sb" >>"$bl"

    run_gate "$sb/plugins" "$bl"
    assert_exit 0 "$GATE_RC" "A file under its baseline passes"

    run_gate "$sb/plugins" "$bl" --regen
    assert_exit 0 "$GATE_RC" "--regen succeeds"
    assert_file_contains "$bl" "450" "--regen tightens the entry to the new smaller size"
    assert_file_not_contains "$bl" " 500" "--regen drops the stale looser number"
}

# --- Classification: the companion arm (#589 §1) -----------------------------

# A skill COMPANION at 700 lines is over the 650 companion budget. Before the
# companion_md arm existed it matched no bloat arm at all. Pins that the gate
# classifies it as a companion, by name.
test_companion_classified() {
    local sb="$WORKDIR/case5"
    make_md "$sb/plugins/p/skills/s/protocol.md" 700
    run_gate "$sb/plugins" "$WORKDIR/case5.baseline"

    assert_exit 1 "$GATE_RC" "An over-budget companion file fails"
    assert_contains "$GATE_OUT" "skill companion" \
        "A skills/<name>/<other>.md is classified as a skill companion"
}

# THE ORDERING RULE. A SKILL.md is ALSO matched by the companion glob
# */skills/*/*.md, so the narrower SKILL.md arm must come first in both the gate
# and the scanner. 520 lines is the ONLY band where this is observable: over the
# 500 skill budget, under the 650 companion budget. Hoisting the companion arm
# makes this file pass, so the case goes red.
test_skill_md_keeps_tighter_budget() {
    local sb="$WORKDIR/case6"
    make_md "$sb/plugins/p/skills/s/SKILL.md" 520
    run_gate "$sb/plugins" "$WORKDIR/case6.baseline"

    assert_exit 1 "$GATE_RC" \
        "A 520-line SKILL.md exceeds the 500 skill budget (not the 650 companion one)"
    assert_contains "$GATE_OUT" "skill definition" \
        "SKILL.md keeps its own tighter budget — the companion arm must not swallow it"
}

# The gate's classification must agree with check-decomposition's scanner — the
# whole "one threshold table" claim rests on it. Asserts the scanner emits the
# same file-type label for the same path shape, so a future edit to one that
# forgets the other is caught here rather than by a puzzled reader.
test_scanner_agrees_on_companion() {
    local sb="$WORKDIR/case7" out
    make_md "$sb/skills/s/protocol.md" 700
    command printf '%s/skills/s/protocol.md\n' "$sb" >"$sb/files.txt"

    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 absent"
        return 0
    fi
    out="$(command python3 \
        "$REPO_ROOT/plugins/review-audit/skills/check-decomposition/patterns.py" \
        "$sb/files.txt" 2>&1 || true)"

    assert_contains "$out" "skill companion" \
        "check-decomposition classifies a companion identically to the gate"
}

# --- Corpus scope ------------------------------------------------------------

# docs/verification/** is exempt BY CONSTRUCTION — outside the walked root, not
# by a filter. What is pinned is the NARROWNESS of the root: widening
# PLUGINS_DIR to the repo root is the plausible regression that would sweep those
# dated transcripts in and pressure someone to edit a session log to fit a
# budget. Asserts the shipped default is the plugins dir specifically.
test_verification_docs_out_of_scope() {
    assert_file_contains "$GATE" 'PLUGINS_DIR="${PROSE_BUDGET_PLUGINS_DIR:-$REPO_ROOT/plugins}"' \
        "The walked root is plugins/, not the repo root (keeps docs/verification out)"
    assert_file_not_contains "$GATE" 'find "$REPO_ROOT" -type f -name' \
        "The gate never walks the whole repo"
}

# A gate whose corpus is empty reports nothing and exits 0 — indistinguishable
# from a pass. Pins that the real corpus is non-empty, so the shipped gate is
# not a no-op.
test_real_corpus_non_empty() {
    local out
    out="$(command bash "$GATE" 2>&1 || true)"
    assert_contains "$out" "files," "The gate reports a file count on the real tree"
    if command printf '%s' "$out" | command grep -qE '^  0 files'; then
        _fail "The real corpus is empty — the gate is a no-op"
    fi
}

# AC1: the gate REPORTS size whether or not it fails. A gate that only speaks up
# on failure gives no data to prioritize reductions from, which is half of what
# #589 asked for.
test_reports_when_passing() {
    local sb="$WORKDIR/case8"
    make_md "$sb/plugins/p/skills/s/SKILL.md" 100
    run_gate "$sb/plugins" "$WORKDIR/case8.baseline"

    assert_exit 0 "$GATE_RC" "A tree within budget passes"
    assert_contains "$GATE_OUT" "Per-skill" "Reports per-skill totals even when passing"
    assert_contains "$GATE_OUT" "total lines" "Reports the aggregate size even when passing"
}

# --- Fail loud, never 77 (AC4) -----------------------------------------------

# The repo's degradation policy reserves 77 for an absent LINTER. This gate's
# runtime is coreutils; its absence is a broken environment. Equally, a missing
# or renamed threshold table must abort rather than fall back to a built-in
# default — a silent default is exactly how the "one table" guarantee would rot
# into two.
test_missing_thresholds_fails_loudly() {
    local sb="$WORKDIR/case9" out rc
    make_md "$sb/plugins/p/skills/s/SKILL.md" 100
    out="$(
        PROSE_BUDGET_PLUGINS_DIR="$sb/plugins" \
            PROSE_BUDGET_BASELINE="$WORKDIR/case9.baseline" \
            PROSE_BUDGET_THRESHOLDS="$WORKDIR/does-not-exist.yml" \
            command bash "$GATE" 2>&1
    )"
    rc=$?

    assert_true "[ $rc -ne 0 ]" "A missing thresholds file must fail, not pass"
    assert_true "[ $rc -ne 77 ]" \
        "It must NOT use the 77 skip sentinel — 77 is for an absent linter"
    assert_contains "$out" "FATAL" "The failure is loud and actionable"
}

# A thresholds file present but missing the key the gate needs must also abort.
# This is the drift case: the table gets reorganized, the gate's key vanishes,
# and a lenient parser would yield an empty value that compares as 0 and flags
# everything — or worse, be treated as "no budget".
test_missing_key_fails_loudly() {
    local sb="$WORKDIR/case10" bad="$WORKDIR/bad-thresholds.yml" out rc
    make_md "$sb/plugins/p/skills/s/SKILL.md" 100
    command printf 'bloat_thresholds:\n  claude_md:\n    high: 600\n' >"$bad"
    out="$(
        PROSE_BUDGET_PLUGINS_DIR="$sb/plugins" \
            PROSE_BUDGET_BASELINE="$WORKDIR/case10.baseline" \
            PROSE_BUDGET_THRESHOLDS="$bad" \
            command bash "$GATE" 2>&1
    )"
    rc=$?

    assert_true "[ $rc -ne 0 ]" "A thresholds file missing a needed key must fail"
    assert_true "[ $rc -ne 77 ]" "Not the skip sentinel"
    assert_contains "$out" "bloat_thresholds" \
        "The failure names the table it could not read"
}

# The thresholds really are READ, not hardcoded. Overriding the table changes the
# verdict on an unchanged file — the only direct evidence that "one threshold
# table" is a live wiring rather than a claim in a comment.
test_thresholds_are_actually_read() {
    local sb="$WORKDIR/case11" tight="$WORKDIR/tight-thresholds.yml"
    make_md "$sb/plugins/p/agents/small.md" 120

    run_gate "$sb/plugins" "$WORKDIR/case11.baseline"
    assert_exit 0 "$GATE_RC" "120 lines is under the real 400 agent budget"

    command printf 'bloat_thresholds:\n' >"$tight"
    command printf '  claude_md:\n    high: 600\n' >>"$tight"
    command printf '  skill_md:\n    high: 500\n' >>"$tight"
    command printf '  agent_md:\n    high: 100\n' >>"$tight"
    command printf '  doc_md:\n    high: 800\n' >>"$tight"
    command printf '  companion_md:\n    high: 650\n' >>"$tight"

    GATE_OUT="$(
        PROSE_BUDGET_PLUGINS_DIR="$sb/plugins" \
            PROSE_BUDGET_BASELINE="$WORKDIR/case11.baseline" \
            PROSE_BUDGET_THRESHOLDS="$tight" \
            command bash "$GATE" 2>&1
    )"
    GATE_RC=$?
    assert_exit 1 "$GATE_RC" \
        "With agent_md.high lowered to 100 the same file now fails — thresholds are read, not hardcoded"
}

# --- The shipped baseline ----------------------------------------------------

# The committed baseline must describe the tree it ships with: every entry names
# a file that exists. A stale entry is a budget nobody is holding.
test_shipped_baseline_is_current() {
    local line path
    assert_file_exists "$SCRIPT_DIR/prose-budget.baseline" "The baseline is committed"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'* | '') continue ;;
        esac
        path="${line%% *}"
        if [ ! -f "$REPO_ROOT/$path" ]; then
            _fail "Baseline names a file that does not exist: $path" \
                "Regenerate with: tests/lint-prose-budget.sh --regen"
        fi
    done <"$SCRIPT_DIR/prose-budget.baseline"
}

# And the real tree must actually pass — the gate lands green (AC2).
test_real_tree_passes() {
    local rc
    command bash "$GATE" >/dev/null 2>&1
    rc=$?
    assert_exit 0 "$rc" "The gate is green against the committed tree"
}

run_test test_over_budget_no_baseline_fails "Over budget with no baseline entry fails"
run_test test_at_baseline_passes "A file at its baseline entry passes"
run_test test_baseline_plus_one_fails "Baseline + 1 line fails (the ratchet's central property)"
run_test test_regen_tightens "--regen tightens a shrunk entry instead of leaving it loose"
run_test test_companion_classified "A skills/<name>/<other>.md is classified as a skill companion"
run_test test_skill_md_keeps_tighter_budget "SKILL.md keeps its tighter budget (arm ordering)"
run_test test_scanner_agrees_on_companion "check-decomposition agrees on the companion label"
run_test test_verification_docs_out_of_scope "docs/verification is out of scope by construction"
run_test test_real_corpus_non_empty "The real corpus is non-empty (gate is not a no-op)"
run_test test_reports_when_passing "Size is reported on a passing run too (AC1)"
run_test test_missing_thresholds_fails_loudly "A missing thresholds file fails loudly, not 77"
run_test test_missing_key_fails_loudly "A thresholds file missing a key fails loudly"
run_test test_thresholds_are_actually_read "Thresholds are parsed from the table, not hardcoded"
run_test test_shipped_baseline_is_current "Every shipped baseline entry names a real file"
run_test test_real_tree_passes "The gate is green against the committed tree (AC2)"

generate_report
