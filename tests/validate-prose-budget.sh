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

# --- Hostile filenames (no shell-out from awk) -------------------------------

# The report block must never build a shell command from a corpus path. Git
# permits almost any byte in a filename except `/` and NUL — including `"`, `$`,
# backticks and `;` — and this gate walks all of plugins/ under CI and pre-push,
# so a path is attacker-influenced by anyone who can add a file in a PR. An
# earlier revision ran `cmd = "wc -l < \"" $0 "\""; cmd | getline` inside awk,
# where such a name escapes the quoting and executes.
#
# The canary is what makes this a real test rather than a smoke test: the
# injected payload would CREATE a file if the substitution were ever evaluated
# by a shell. Asserting merely that the gate "still exits 0" would pass just as
# well against the vulnerable version, since the injected command succeeds
# quietly — that is the tautological-fixture shape this repo has been bitten by.
test_hostile_filename_is_not_executed() {
    local sb="$WORKDIR/case12" canary_name="case12-canary-589"
    # Two constraints on the payload, BOTH verified empirically — a fixture that
    # merely looks hostile is the tautological shape this repo keeps getting bitten
    # by, and both mistakes were made and caught while writing this test:
    #
    # (1) NO `/`. That is the one byte a filename cannot hold, so an absolute
    #     canary path makes the fixture unrepresentable and the test skips
    #     itself — hiding the very branch it exists to cover. A bare relative
    #     name lands in the awk process's cwd (the gate's cwd) instead.
    # (2) NO leading `"`. Inside `wc -l < "<path>"` a `"` CLOSES the quote and
    #     `sh` dies on "Unterminated quoted string" BEFORE reaching the
    #     substitution — so a quote-bearing payload passes against the
    #     vulnerable code and proves nothing. `$(...)` alone inside the intact
    #     quotes is what actually executes (verified: it created the canary
    #     against the pre-fix implementation).
    local hostile='ok$(touch '"$canary_name"').md'
    local landed="$REPO_ROOT/$canary_name"

    command mkdir -p "$sb/plugins/p/skills/s"
    if ! command touch "$sb/plugins/p/skills/s/$hostile" 2>/dev/null; then
        skip_test "filesystem rejects the hostile filename"
        return 0
    fi
    make_md "$sb/plugins/p/skills/s/$hostile" 10
    command rm -f "$landed"

    run_gate "$sb/plugins" "$WORKDIR/case12.baseline"

    assert_exit 0 "$GATE_RC" "A hostile filename does not crash the gate"
    assert_true "[ ! -e '$landed' ]" \
        "The injected \$(touch …) never executed — no shell-out from awk"
    command rm -f "$landed"
}

# Structural backstop for the same rule. The canary above proves the CURRENT
# code does not execute the payload; this pins that the mechanism cannot come
# back, since a future edit could reintroduce a `cmd | getline` with a filename
# that happens not to trip the canary fixture.
test_no_shellout_from_awk() {
    assert_file_not_contains "$GATE" 'cmd | getline' \
        "The report awk never pipes a built command through getline"
    assert_file_not_contains "$GATE" 'wc -l < \"' \
        "No shell wc invocation is built from an interpolated awk field"
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

# --- The exceptions ledger: rationales ---------------------------------------
#
# The budgets are TARGETS, not laws — a file that is genuinely better long stays
# long. The risk is not any single exception but exceptions ACCUMULATING
# UNNOTICED until the budget means nothing, so each baseline entry carries an
# optional trailing `# why` and the gate surfaces the ledger on every run.
#
# Three properties worth pinning, because each has a silent failure mode:
#   1. an entry WITH a rationale still parses its count (a naive `${rest##* }`
#      returns the empty string once a trailing space precedes the `#`, which
#      would stop ratcheting that file entirely while the run still looked fine);
#   2. --regen PRESERVES rationales (a regen that dropped them would erase every
#      justification on a routine shrink, keeping the numbers and losing the
#      reasons);
#   3. an entry WITHOUT a rationale is named, so an unjustified exception cannot
#      blend into a count.

# A rationaled entry must ratchet exactly like a bare one: at its entry it
# passes, one line above it fails.
test_rationale_entry_still_ratchets() {
    local sb="$WORKDIR/rat1"
    make_md "$sb/plugins/p/agents/big.md" 500
    # Both path spellings — see test_at_baseline_passes: a sandbox outside the
    # repo root keeps its absolute path, while the shipped baseline is relative.
    command printf 'plugins/p/agents/big.md 500 # deliberately whole, see #503\n' \
        >"$WORKDIR/rat1.baseline"
    command printf '%s/plugins/p/agents/big.md 500 # deliberately whole, see #503\n' \
        "$sb" >>"$WORKDIR/rat1.baseline"
    run_gate "$sb/plugins" "$WORKDIR/rat1.baseline"
    assert_exit 0 "$GATE_RC" "A rationaled entry passes at its recorded count"

    # One line above the entry must fail — proves the count was really parsed
    # and not silently read as empty.
    make_md "$sb/plugins/p/agents/big.md" 501
    run_gate "$sb/plugins" "$WORKDIR/rat1.baseline"
    assert_exit 1 "$GATE_RC" "A rationaled entry still fails on growth"
}

# The rationale is echoed in the report, so the ledger is readable on every run.
test_rationale_is_reported() {
    local sb="$WORKDIR/rat2"
    make_md "$sb/plugins/p/agents/big.md" 500
    command printf 'plugins/p/agents/big.md 500 # cohesive by design\n' \
        >"$WORKDIR/rat2.baseline"
    command printf '%s/plugins/p/agents/big.md 500 # cohesive by design\n' \
        "$sb" >>"$WORKDIR/rat2.baseline"
    run_gate "$sb/plugins" "$WORKDIR/rat2.baseline"
    assert_contains "$GATE_OUT" "cohesive by design" \
        "The report prints each exception's rationale"
}

# An exception with no rationale is named, not merely counted.
test_missing_rationale_is_named() {
    local sb="$WORKDIR/rat3"
    make_md "$sb/plugins/p/agents/big.md" 500
    command printf 'plugins/p/agents/big.md 500\n' >"$WORKDIR/rat3.baseline"
    command printf '%s/plugins/p/agents/big.md 500\n' "$sb" >>"$WORKDIR/rat3.baseline"
    run_gate "$sb/plugins" "$WORKDIR/rat3.baseline"
    assert_contains "$GATE_OUT" "NO RATIONALE RECORDED" \
        "An unjustified exception is called out by name"
    assert_exit 0 "$GATE_RC" \
        "A missing rationale REPORTS but does not fail (the ratchet already guards growth)"
}

# --regen must carry existing rationales forward. Without this a routine shrink
# silently erases every justification in the ledger.
test_regen_preserves_rationale() {
    local sb="$WORKDIR/rat4" bl="$WORKDIR/rat4.baseline"
    make_md "$sb/plugins/p/agents/big.md" 500
    command printf 'plugins/p/agents/big.md 500 # keep me across regen\n' >"$bl"
    command printf '%s/plugins/p/agents/big.md 500 # keep me across regen\n' "$sb" >>"$bl"

    # Shrink the file, then regen: the entry tightens, the reason survives.
    make_md "$sb/plugins/p/agents/big.md" 450
    run_gate "$sb/plugins" "$bl" --regen

    assert_true "command grep -q 'keep me across regen' '$bl'" \
        "--regen preserves an existing rationale"
    assert_true "command grep -q 'big.md 450' '$bl'" \
        "--regen tightens the entry to the new count"
}

# A snapshot that cannot be taken must ABORT, not quietly regen. Without this
# the mktemp-failure path re-creates the very data loss the snapshot prevents:
# an empty REGEN_PREV sends every rationale lookup at `[ -f "" ]`, so the new
# baseline is written with every `# why` note dropped — silently, which this
# gate's header explicitly rules out.
#
# TMPDIR is pointed at a non-existent path to force mktemp to fail; the real
# temp dir is untouched.
test_regen_aborts_when_snapshot_fails() {
    local sb="$WORKDIR/rat5" bl="$WORKDIR/rat5.baseline" out rc=0
    make_md "$sb/plugins/p/agents/big.md" 500
    command printf 'plugins/p/agents/big.md 500 # must survive or abort\n' >"$bl"
    command printf '%s/plugins/p/agents/big.md 500 # must survive or abort\n' "$sb" >>"$bl"

    out="$(
        TMPDIR="$WORKDIR/no-such-dir" \
            PROSE_BUDGET_PLUGINS_DIR="$sb/plugins" \
            PROSE_BUDGET_BASELINE="$bl" \
            PROSE_BUDGET_THRESHOLDS="$REAL_THRESHOLDS" \
            command bash "$GATE" --regen 2>&1
    )" || rc=$?

    assert_true "[ $rc -ne 0 ]" "A failed snapshot aborts the regen (never a silent drop)"
    assert_contains "$out" "FATAL" "The abort is loud, naming the failure"
    # The load-bearing half: the ledger on disk is untouched, rationale intact.
    assert_true "command grep -q 'must survive or abort' '$bl'" \
        "The existing baseline is left intact when the snapshot fails"
}

# A trapped INT/TERM must ABORT the regen, not merely clean up and continue.
#
# bash resumes at the next statement after a trapped signal UNLESS the handler
# exits. So a cleanup-only handler (`trap 'rm -f "$SNAP"' INT`) would delete the
# snapshot and then fall through into the rationale loop below, reading a
# deleted file and writing a baseline with every `# why` note dropped — this
# fix's own data loss, reached by the signal path.
#
# Asserted STRUCTURALLY rather than by firing a real signal. Driving SIGINT from
# inside run_test proved genuinely flaky: the suite has its own signal
# disposition and job control, so the signal can land before the child has even
# exec'd, and the observable outcome varies run to run. A flaky test is worse
# than no test — it teaches people to ignore red. The property here is a fixed
# fact about the script's trap wiring, so read the wiring.
test_regen_signal_traps_exit() {
    local int_trap term_trap
    int_trap="$(command grep -E "^ *trap .* INT$" "$GATE" || true)"
    term_trap="$(command grep -E "^ *trap .* TERM$" "$GATE" || true)"

    assert_not_empty "$int_trap" "An INT trap is armed for the regen snapshot"
    assert_not_empty "$term_trap" "A TERM trap is armed for the regen snapshot"

    # The load-bearing half: each signal handler must exit. Without it the
    # handler returns and execution continues past the signal.
    #
    # Pinned to the EXACT code, not a bare "exit": `trap 'exit 0' INT` also
    # contains the substring, exits, and would satisfy a loose assertion — while
    # reporting an interrupted regen as a clean success to any caller that reads
    # the status, and dropping the cleanup. 130/143 are the conventional
    # 128+signum codes.
    assert_contains "$int_trap" "exit 130" \
        "The INT handler exits 130 (bash would otherwise resume into the regen)"
    assert_contains "$term_trap" "exit 143" \
        "The TERM handler exits 143 (bash would otherwise resume into the regen)"

    # Exit AND clean up have to travel together, on the SAME line. Asserting
    # cleanup only for the EXIT trap would leave a handler narrowed to
    # `trap 'exit 130' INT` green while it leaks the snapshot on every Ctrl-C.
    assert_contains "$int_trap" "rm -f" \
        "The INT handler still removes the snapshot before exiting"
    assert_contains "$term_trap" "rm -f" \
        "The TERM handler still removes the snapshot before exiting"

    # And a plain EXIT trap still handles the normal path.
    assert_true "command grep -qE \"^ *trap .* EXIT\$\" '$GATE'" \
        "An EXIT trap cleans up the snapshot on the normal path"
}

# The snapshot `cat` is a SECOND, independently-guarded failure branch: mktemp
# can succeed and the copy still fail. Drive it by making the source baseline
# unreadable, so only that branch can fire.
#
# Skipped when running as root, where chmod 000 does not deny reads.
test_regen_aborts_when_snapshot_copy_fails() {
    local sb="$WORKDIR/rat7" bl="$WORKDIR/rat7.baseline" out rc=0

    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — chmod 000 does not deny reads"
        return 0
    fi

    make_md "$sb/plugins/p/agents/big.md" 500
    command printf 'plugins/p/agents/big.md 500 # unreadable-source guard\n' >"$bl"
    command printf '%s/plugins/p/agents/big.md 500 # unreadable-source guard\n' "$sb" >>"$bl"
    command chmod 000 "$bl"

    out="$(
        PROSE_BUDGET_PLUGINS_DIR="$sb/plugins" \
            PROSE_BUDGET_BASELINE="$bl" \
            PROSE_BUDGET_THRESHOLDS="$REAL_THRESHOLDS" \
            command bash "$GATE" --regen 2>&1
    )" || rc=$?

    command chmod 644 "$bl"

    assert_true "[ $rc -ne 0 ]" "An unreadable baseline aborts the regen"
    assert_contains "$out" "FATAL" "The copy-failure abort is loud"
    assert_true "command grep -q 'unreadable-source guard' '$bl'" \
        "The ledger is left intact when the snapshot copy fails"
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
run_test test_hostile_filename_is_not_executed "A hostile filename is never executed (no awk shell-out)"
run_test test_no_shellout_from_awk "The report awk builds no shell command (structural)"
run_test test_missing_thresholds_fails_loudly "A missing thresholds file fails loudly, not 77"
run_test test_missing_key_fails_loudly "A thresholds file missing a key fails loudly"
run_test test_thresholds_are_actually_read "Thresholds are parsed from the table, not hardcoded"
run_test test_shipped_baseline_is_current "Every shipped baseline entry names a real file"
run_test test_rationale_entry_still_ratchets "A rationaled baseline entry still ratchets"
run_test test_rationale_is_reported "Each exception's rationale is reported"
run_test test_missing_rationale_is_named "An exception with no rationale is named"
run_test test_regen_preserves_rationale "--regen preserves rationales while tightening"
run_test test_regen_aborts_when_snapshot_fails "--regen aborts loudly if the snapshot fails"
run_test test_regen_aborts_when_snapshot_copy_fails "--regen aborts loudly if the snapshot COPY fails"
run_test test_regen_signal_traps_exit "The regen INT/TERM traps exit rather than resume"

run_test test_real_tree_passes "The gate is green against the committed tree (AC2)"

generate_report
