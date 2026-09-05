#!/usr/bin/env bash
# Behavior gate for bin/ai-config-prescan.sh — the scheduled ai-config pre-scan
# ratchet (issue #907).
#
# WHAT THIS PINS, AND WHY IT IS NOT THE SCAN ITSELF. The scanner runs on a
# SCHEDULE (.github/workflows/ai-config-prescan.yml), deliberately not as a
# per-PR gate: #551 moved that coverage off the per-PR path, and re-adding it to
# run-all.sh would reverse the decision #907 exists to follow up on. So this
# suite is the META-gate — it exercises the script's RATCHET LOGIC against
# fixtures, the same split the repo already runs between lint-prose-budget.sh
# (the gate, over the real corpus) and validate-prose-budget.sh (its behavior).
#
# THE CENTRAL PROPERTY is that a finding NOT in the baseline fails the run. A
# suite that only asserted the current tree is green would pass just as happily
# with the comparison deleted — the ratchet would be inert and nobody would know
# until a real violation sailed through. Every fixture below is therefore built
# on the arm that DISAGREES when the logic it targets is removed.
#
# FIXTURES, NOT THE LIVE TREE. Each case builds a throwaway git repo in
# `mktemp -d` with its own plugins/ corpus and its own baseline, and points the
# script at it via AI_CONFIG_PRESCAN_ROOT / AI_CONFIG_PRESCAN_BASELINE. Nothing
# here reads or writes the real repo's baseline — a test that regenerated the
# live ledger would silently launder a real finding into "known", which is the
# side-effect-invisible-to-the-assertion shape.
#
# Pure bash + coreutils + git. bash-3.2 clean per CLAUDE.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

PRESCAN_SH="$REPO_ROOT/bin/ai-config-prescan.sh"
CHECK_AI_CONFIG="plugins/review-audit/skills/check-ai-config"

test_suite "ai-config pre-scan ratchet (#907)"

# --- fixture construction ----------------------------------------------------

# make_sandbox — build a throwaway repo whose corpus is under our control.
# Echoes the sandbox path. The real check-ai-config skill is COPIED in (not
# symlinked) so the scanner under test is the genuine one while the corpus is
# synthetic.
#
# Two SKILL.md files: `clean.md` HAS a structural section (no finding) and
# `dirty.md` has none (one `skill-frontmatter` finding). That pair is what lets
# a case move a single finding in or out of the baseline.
make_sandbox() {
    local box
    box="$(command mktemp -d)" || return 1

    command mkdir -p "$box/plugins/testplug/skills/clean" \
        "$box/plugins/testplug/skills/dirty" \
        "$box/$(command dirname "$CHECK_AI_CONFIG")"
    command cp -R "$REPO_ROOT/$CHECK_AI_CONFIG" "$box/$CHECK_AI_CONFIG"

    command cat >"$box/plugins/testplug/skills/clean/SKILL.md" <<'EOF'
---
name: clean
description: A skill whose prose carries a structural section, so the deterministic pre-scan finds nothing to report about it.
---

# Clean

## Workflow

1. Do the thing.
EOF

    command cat >"$box/plugins/testplug/skills/dirty/SKILL.md" <<'EOF'
---
name: dirty
description: A skill with no structural section at all, which is the one MEDIUM skill-frontmatter finding this fixture is built to produce.
---

# Dirty

Some prose with no structural heading of any kind.
EOF

    # Both skills get a metadata.yml. The pre-scan carries a SECOND
    # skill-frontmatter detector ("Missing metadata.yml in skill directory"), and
    # without these files each fixture skill would emit TWO findings instead of
    # one. That extra row is not what any case here is about, and it would let a
    # case pass on the wrong finding -- the assertions below count rows, so a
    # stray detector silently changes what "1 new finding" means.
    local skill
    for skill in clean dirty; do
        command cat >"$box/plugins/testplug/skills/$skill/metadata.yml" <<EOF
name: $skill
version: "1.0"
labels: []
EOF
    done

    (
        cd "$box" || exit 1
        command git init -q .
        command git add -A
    ) >/dev/null 2>&1 || return 1

    command printf '%s' "$box"
}

# run_prescan <sandbox> <baseline> [arg] — run the script under test against a
# sandbox. Sets RC and OUT. Never aborts the caller on a non-zero exit, since a
# non-zero exit is the thing most cases are asserting.
RC=0
OUT=""
run_prescan() {
    local box="$1" baseline="$2" arg="${3:-}"
    RC=0
    OUT="$(AI_CONFIG_PRESCAN_ROOT="$box" AI_CONFIG_PRESCAN_BASELINE="$baseline" \
        bash "$PRESCAN_SH" $arg 2>&1)" || RC=$?
}

# baseline_with <path> <lines...> — write a baseline ledger carrying a comment
# header (so the comment-stripping path is exercised, not bypassed) plus the
# given key lines.
baseline_with() {
    local path="$1"
    shift
    {
        command printf '# fixture baseline — comments and blanks must be ignored\n'
        command printf '\n'
        local l
        for l in "$@"; do
            command printf '%s\n' "$l"
        done
    } >"$path"
}

DIRTY_KEY="plugins/testplug/skills/dirty/SKILL.md	skill-frontmatter	No structural section found (expected ## Workflow, ## Categories, or similar)"

# --- Cases -------------------------------------------------------------------

# The green arm. On its own this proves little (see the header) — it is here as
# the control the failing cases are contrasted against.
test_baselined_finding_passes() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $box now, at trap-registration time
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline"

    assert_exit 0 "$RC" "A finding present in the baseline must not fail the run"
    assert_contains "$OUT" "new (not baselined): **0**" "Baselined finding must not count as new"
    assert_contains "$OUT" "findings in tree: **1**" "The finding must still be COUNTED, not filtered away"
}

# THE CENTRAL PROPERTY. Delete the comm/diff and this is the case that goes red.
test_new_finding_fails() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    # An EMPTY baseline (header only): the dirty file's finding is unbaselined.
    baseline_with "$box/baseline"
    run_prescan "$box" "$box/baseline"

    assert_exit 1 "$RC" "A finding absent from the baseline MUST fail the run"
    assert_contains "$OUT" "NEW findings (1)" "The failure must say how many are new"
    assert_contains "$OUT" "dirty/SKILL.md" "The failure must NAME the offending file"
}

# Narrowness: the failure above must be caused by the finding being unbaselined,
# not by the scanner failing whenever any finding exists. A baseline holding a
# DIFFERENT file's finding must still fail on the dirty one — this is what
# separates a real key comparison from "non-empty baseline => pass".
test_wrong_baseline_entry_still_fails() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline" \
        "plugins/testplug/skills/somewhere-else/SKILL.md	skill-frontmatter	No structural section found (expected ## Workflow, ## Categories, or similar)"
    run_prescan "$box" "$box/baseline"

    assert_exit 1 "$RC" "A baseline entry for a DIFFERENT file must not excuse this finding"
    assert_contains "$OUT" "dirty/SKILL.md" "The real offender must be named"
}

# The baseline key is file+category+evidence and must NOT include the line
# number. Prepending lines to the dirty file shifts its finding's line number;
# the run must stay green. Without this, every unrelated edit would report the
# known findings as new and the job would be muted as noise.
test_line_number_churn_does_not_create_new_findings() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline" "$DIRTY_KEY"

    # Insert filler AFTER the frontmatter so the finding's reported line moves.
    local f="$box/plugins/testplug/skills/dirty/SKILL.md"
    command cat >"$f.new" <<'EOF'
---
name: dirty
description: A skill with no structural section at all, which is the one MEDIUM skill-frontmatter finding this fixture is built to produce.
---

# Dirty

Filler paragraph one, added to shift every subsequent line number.

Filler paragraph two, added to shift every subsequent line number.

Filler paragraph three, added to shift every subsequent line number.

Some prose with no structural heading of any kind.
EOF
    command mv "$f.new" "$f"
    (cd "$box" && command git add -A) >/dev/null 2>&1

    run_prescan "$box" "$box/baseline"
    assert_exit 0 "$RC" "Line-number churn must not turn a baselined finding into a new one"
    assert_contains "$OUT" "new (not baselined): **0**" "Key must exclude the line number"
}

# A baselined finding that has been FIXED reports as absent and stays green —
# the ratchet only ever tightens; it never demands the finding come back.
test_fixed_finding_reported_not_failed() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    # Baseline claims BOTH files are findings; only `dirty` actually is.
    baseline_with "$box/baseline" "$DIRTY_KEY" \
        "plugins/testplug/skills/clean/SKILL.md	skill-frontmatter	No structural section found (expected ## Workflow, ## Categories, or similar)"
    run_prescan "$box" "$box/baseline"

    assert_exit 0 "$RC" "A baselined finding that no longer appears must not fail"
    assert_contains "$OUT" "baselined but now absent: **1**" "The disappeared finding must be reported"
    assert_contains "$OUT" "--regen" "The report must say how to tighten the ratchet"
}

# --regen round-trip: regenerating makes a previously-failing tree pass, and the
# written ledger holds the real key. This also pins that --regen writes to the
# override path, never to the live repo baseline.
test_regen_round_trip() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline"
    run_prescan "$box" "$box/baseline"
    assert_exit 1 "$RC" "Precondition: the tree must be failing before regen"

    run_prescan "$box" "$box/baseline" "--regen"
    assert_exit 0 "$RC" "--regen must succeed"
    assert_file_exists "$box/baseline" "--regen must write the baseline"

    local written
    written="$(command grep -c 'dirty/SKILL.md' "$box/baseline" || true)"
    assert_equals "1" "$written" "The regenerated baseline must hold the real finding key"

    run_prescan "$box" "$box/baseline"
    assert_exit 0 "$RC" "After regen the same tree must pass"
}

# A MISSING baseline must fail loud (exit 2), not be treated as an empty one and
# not pass. Silence here would be indistinguishable from a clean scan — the
# #538/#571 inert-gate shape — and a path typo would look like a real
# regression.
test_missing_baseline_fails_loud() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    run_prescan "$box" "$box/does-not-exist"
    assert_exit 2 "$RC" "A missing baseline must exit 2 (fail loud), not 0 or 1"
    assert_contains "$OUT" "baseline not found" "The error must say what is missing"
}

# An absent scanner must exit 2 rather than reporting a clean tree. This is the
# case that separates "no findings" from "no scan": with the guard removed the
# script would emit zero rows and exit 0, which reads as success forever.
test_missing_scanner_fails_loud() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    command rm -f "$box/$CHECK_AI_CONFIG/patterns.sh"
    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline"

    assert_exit 2 "$RC" "An absent pre-scan must exit 2, never report a clean scan"
    assert_contains "$OUT" "FATAL" "The failure must be loud"
}

# An empty corpus must fail loud too. A wrong root, or a filter that stopped
# matching, scans zero files and finds nothing — a pass for entirely the wrong
# reason. This is the whole-repo-diff-bounded-by-repo-content shape.
test_empty_corpus_fails_loud() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    (cd "$box" && command git rm -r -q --cached plugins >/dev/null 2>&1) || true
    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline"

    assert_exit 2 "$RC" "An empty corpus must exit 2, not pass as 'no findings'"
    assert_contains "$OUT" "no tracked" "The error must name the empty-corpus cause"
}

# An unknown argument is a usage error (exit 1), not a silently-ignored flag
# that runs a normal scan. A typo'd `--regen` must not quietly report instead.
test_unknown_argument_rejected() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline" "--regenerate"
    assert_exit 1 "$RC" "An unknown argument must be a usage error"
    assert_contains "$OUT" "unknown argument" "The error must name the bad argument"
}

# The output must not overclaim. AC#3 binds the job to what it performs: the
# report has to say the LLM-judgment half is NOT covered, or a reader will take
# a green run as evidence the whole convention sweep passed.
test_output_disclaims_the_judgment_half() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline"

    # Anchor on the DISCLAIMER SENTENCE, not on the bare phrase "deterministic
    # half" -- the report HEADING carries that phrase too, so a looser assertion
    # stays green with the whole disclaimer deleted (a surviving mutation caught
    # exactly that).
    assert_contains "$OUT" "This job covers the **deterministic half only**" \
        "Output must carry the explicit deterministic-half-only disclaimer"
    assert_contains "$OUT" "LLM-judgment half" "Output must name what it does NOT cover"
    assert_contains "$OUT" "convention-cadence.md" "Output must point at the ritual that covers the rest"
    assert_not_contains "$OUT" "convention audit passed" "Output must never claim the full sweep ran"
}

# The scanner PRESENT but FAILING must also exit 2. This is a different branch
# from the absent-scanner case above: that one short-circuits on the `-f` guard
# and never reaches the exit-code check, so without this case the scanner's
# non-zero exit could be ignored entirely and every test would still pass (a
# surviving mutation proved it). Both of the scanner's own error exits -- 1 for
# a usage error, 2 for an absent runtime -- emit ZERO rows, which is precisely
# the reading that must not be mistaken for a clean tree.
test_failing_scanner_fails_loud() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    # Replace the scanner with one that exits non-zero and prints nothing --
    # the exact shape of a broken runtime or a usage error.
    command cat >"$box/$CHECK_AI_CONFIG/patterns.sh" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
    # The Python primary would be exec'd ahead of the bash body and mask the
    # stub, so it has to go too.
    command rm -f "$box/$CHECK_AI_CONFIG/patterns.py"

    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline"

    assert_exit 2 "$RC" "A pre-scan that EXITS non-zero must exit 2, not report a clean tree"
    assert_contains "$OUT" "not a clean tree" "The failure must say zero rows != clean"
}

# The corpus is markdown-only, which means three of check-ai-config's categories
# (mcp-misconfiguration, hook-safety, harness-logic) can never fire from this
# job -- their detectors gate on *.json / *.sh / *workflow.js. That narrowing is
# deliberate and measured (see the script header: broadening adds 31 rows, all
# false positives), but a DELIBERATE scope limit and an ACCIDENTAL one look
# identical from the outside, and this is the exact shape -- a scan that reads
# clean for reasons unrelated to the tree -- the rest of this suite guards
# against. So pin it: a .json and a .sh dropped into the corpus with content
# those detectors WOULD flag must still produce no new findings. If someone
# widens the git ls-files filter, this case fails and makes them re-measure.
test_corpus_is_markdown_only() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    # Content each excluded detector would fire on if the file were scanned:
    # an insecure URL (mcp-misconfiguration) and a destructive command
    # (hook-safety). Both are inert while the corpus stays markdown-only.
    command cat >"$box/plugins/testplug/bait.json" <<'BAIT'
{ "url": "http://example.com/insecure" }
BAIT
    command cat >"$box/plugins/testplug/bait.sh" <<'BAIT'
#!/usr/bin/env bash
rm -rf /some/path
BAIT
    (cd "$box" && command git add -A) >/dev/null 2>&1

    baseline_with "$box/baseline" "$DIRTY_KEY"
    run_prescan "$box" "$box/baseline"

    assert_exit 0 "$RC" "Non-markdown files must not enter the corpus"
    assert_contains "$OUT" "findings in tree: **1**" \
        "Corpus must stay markdown-only (a .json/.sh entering it changes this count)"
    assert_not_contains "$OUT" "bait." "No non-markdown file may be reported"
}

# The GITHUB_STEP_SUMMARY branch is CI-only, so nothing else here executes it --
# a mutation dropping the second write, or writing to the wrong file, would
# survive the whole suite. A scheduled job's stdout is effectively invisible, so
# the summary IS the report for its actual audience.
test_step_summary_receives_the_report() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    baseline_with "$box/baseline" "$DIRTY_KEY"
    RC=0
    OUT="$(AI_CONFIG_PRESCAN_ROOT="$box" AI_CONFIG_PRESCAN_BASELINE="$box/baseline" \
        GITHUB_STEP_SUMMARY="$box/summary" bash "$PRESCAN_SH" 2>&1)" || RC=$?

    assert_exit 0 "$RC" "The summary path must not change the verdict"
    assert_file_exists "$box/summary" "GITHUB_STEP_SUMMARY must be written"
    local summary
    summary="$(command cat "$box/summary" 2>/dev/null || true)"
    assert_contains "$summary" "findings in tree" "The summary must carry the report body"
    assert_contains "$summary" "deterministic half" "The summary must carry the scope disclaimer"
}

# --regen must BOOTSTRAP: with no baseline file at all it writes one rather than
# hitting the missing-baseline fatal. The round-trip case starts from an
# existing (empty-bodied) ledger, so it never covers first-run creation -- the
# path a new checkout or a renamed baseline actually takes.
test_regen_bootstraps_without_a_baseline() {
    local box
    box="$(make_sandbox)" || {
        skip_test "mktemp/git unavailable"
        return 0
    }
    # shellcheck disable=SC2064
    trap "command rm -rf '$box'" RETURN

    run_prescan "$box" "$box/fresh-baseline" "--regen"
    assert_exit 0 "$RC" "--regen must create a baseline that does not yet exist"
    assert_file_exists "$box/fresh-baseline" "--regen must write the new ledger"

    run_prescan "$box" "$box/fresh-baseline"
    assert_exit 0 "$RC" "The bootstrapped baseline must make the same tree pass"
}

run_test test_baselined_finding_passes "A baselined finding passes"
run_test test_new_finding_fails "A NEW finding fails the run (central property)"
run_test test_wrong_baseline_entry_still_fails "A baseline entry for another file does not excuse it"
run_test test_line_number_churn_does_not_create_new_findings "Line-number churn creates no new findings"
run_test test_fixed_finding_reported_not_failed "A fixed finding is reported, not failed"
run_test test_regen_round_trip "--regen round-trips a failing tree to green"
run_test test_missing_baseline_fails_loud "A missing baseline exits 2 (fail loud)"
run_test test_missing_scanner_fails_loud "An absent pre-scan exits 2, never 'clean'"
run_test test_failing_scanner_fails_loud "A FAILING pre-scan exits 2, never 'clean'"
run_test test_empty_corpus_fails_loud "An empty corpus exits 2, not a false pass"
run_test test_unknown_argument_rejected "An unknown argument is a usage error"
run_test test_output_disclaims_the_judgment_half "Output disclaims the LLM-judgment half"
run_test test_corpus_is_markdown_only "Corpus stays markdown-only (scope is pinned)"
run_test test_step_summary_receives_the_report "GITHUB_STEP_SUMMARY receives the report"
run_test test_regen_bootstraps_without_a_baseline "--regen bootstraps with no baseline"

generate_report
