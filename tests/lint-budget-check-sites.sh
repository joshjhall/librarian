#!/usr/bin/env bash
# Context-budget check-site gate (#1057).
#
# context-budget.sh owns the arithmetic and the model performs the handoff — so
# the verdict is only worth anything if the check is REACHED. #1057 measured
# five golems that ran to 170k-400k and executed it zero times: its one site,
# golem/SKILL.md § Phase C, is never loaded by an orchestrated golem (launched as
# a bare /workflow:next-issue), and the L3-L4 exception bypasses every reset
# point. Nothing errored; the check was simply never on the path. That is a
# source-shape defect no fixture can catch, so this gate reads the source.
#
# What it pins, per required site (see handoff-protocol.md § Where the check runs):
#   * the site is marked EXACTLY ONCE across the walked skills — zero means the
#     check fell off the path again; two means a copy that will drift;
#   * its block carries the worktree-safe recipe — a ${CLAUDE_PLUGIN_ROOT} or
#     $PWD spelling is refused worktree-isolated, which makes the reading
#     unavailable for the whole run, silently (#809/#815);
#   * its block names `handoff_marker` — the relaunch detector
#     (golem-handoff-relaunch.sh) keys on it, and a checkpoint without one is a
#     handoff the orchestrator can never resume;
#   * it sits in the right PLACE — impl-done before the hand-off step that
#     invokes ship, review-cycle inside the multi-cycle loop — so a move that
#     orphans a site fails here instead of passing a count.
# Plus: the canonical block prints the UNKNOWN line (an unreadable budget must
# not look like `ok`), and the relaunch step exists in monitor-protocol.md.
#
# Every rule is mutation-proved against a synthetic tree in the negative cases
# below; a gate with no failing fixture is a gate nobody has seen fire.
#
# bash-3.2 clean; BSD grep/sed safe (no -P, no \s).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Context-budget check sites (#1057)"

# Explicit, ordered: site name -> the file it must live in.
SITES="plan-approved:next-issue/phase2-plan.md
impl-done:next-issue/phase2-plan.md
review-cycle:ship-issue/ci-review-protocol.md"

RECIPE='<skill-base-dir>/../../scripts/context-budget.sh check .'

# _block <file> <site> — the text between a site's open and end markers.
_block() {
    command awk -v open="<!-- budget-check-site: $2 -->" '
        index($0, open) { on = 1; next }
        on && index($0, "<!-- end-budget-check-site -->") { exit }
        on { print }' "$1"
}

# _line_of <file> <fixed-string> — first line number containing it, or 0.
_line_of() {
    local n
    n="$(command grep -n -F -e "$2" "$1" 2>/dev/null | command head -n 1 | command cut -d: -f1)" || true
    command printf '%s' "${n:-0}"
}

# check_tree <skills-dir> — run every rule against a skills tree. Prints one line
# per violation; returns 1 when any fired. Separate from the run_test wrappers
# so the negative fixtures exercise the SAME code the real tree does.
check_tree() {
    local skills="$1" bad=0 entry site rel f count block
    for entry in $SITES; do
        site="${entry%%:*}"
        rel="${entry#*:}"
        f="$skills/$rel"
        count="$(command grep -r -F -e "<!-- budget-check-site: $site -->" "$skills" 2>/dev/null | command wc -l | command tr -d ' ')"
        if [ "$count" != "1" ]; then
            command echo "site $site: marked $count times (want exactly 1)"
            bad=1
            continue
        fi
        if [ "$(_line_of "$f" "<!-- budget-check-site: $site -->")" = "0" ]; then
            command echo "site $site: not in $rel"
            bad=1
            continue
        fi
        block="$(_block "$f" "$site")"
        case "$block" in
            *"$RECIPE"*) ;;
            *)
                command echo "site $site: block lacks the worktree-safe recipe"
                bad=1
                ;;
        esac
        case "$block" in
            *'CLAUDE_PLUGIN_ROOT'* | *'$PWD'* | *'${PWD}'*)
                command echo "site $site: block uses a spelling refused worktree-isolated"
                bad=1
                ;;
        esac
        case "$block" in
            *handoff*) ;;
            *)
                command echo "site $site: block does not say what to do on handoff"
                bad=1
                ;;
        esac
    done

    # Placement. impl-done must precede the hand-off step; review-cycle must sit
    # after the loop heading and before its convergence step.
    local plan="$skills/next-issue/phase2-plan.md" rev="$skills/ship-issue/ci-review-protocol.md"
    local a b lo hi
    a="$(_line_of "$plan" '<!-- budget-check-site: impl-done -->')"
    b="$(_line_of "$plan" '**Hand off — suggest a context reset')"
    if [ "$a" = "0" ] || [ "$b" = "0" ] || [ "$a" -ge "$b" ]; then
        command echo "placement: impl-done (line $a) must precede the hand-off step (line $b)"
        bad=1
    fi
    a="$(_line_of "$plan" '<!-- budget-check-site: plan-approved -->')"
    b="$(_line_of "$plan" '1. **Implement**')"
    if [ "$a" = "0" ] || [ "$b" = "0" ] || [ "$a" -le "$b" ]; then
        command echo "placement: plan-approved (line $a) must sit inside the Implement step (line $b)"
        bad=1
    fi
    a="$(_line_of "$rev" '<!-- budget-check-site: review-cycle -->')"
    lo="$(_line_of "$rev" '## Multi-cycle PR review loop')"
    hi="$(_line_of "$rev" 'f. **Consult the convergence predicate**')"
    if [ "$a" = "0" ] || [ "$lo" = "0" ] || [ "$hi" = "0" ] || [ "$a" -le "$lo" ] || [ "$a" -ge "$hi" ]; then
        command echo "placement: review-cycle (line $a) must sit inside the review loop, before step (f)"
        bad=1
    fi

    # The canonical block: the UNKNOWN report and the marker requirement.
    local proto="$skills/next-issue/handoff-protocol.md"
    if ! command grep -F -e 'context budget: UNKNOWN (exit <n>)' "$proto" >/dev/null 2>&1; then
        command echo "handoff-protocol.md: no UNKNOWN report line — an unreadable budget would read as ok"
        bad=1
    fi
    if ! command grep -F -e 'handoff_marker' "$proto" >/dev/null 2>&1; then
        command echo "handoff-protocol.md: does not require handoff_marker on a handoff"
        bad=1
    fi

    # The relaunch half: without it a honored verdict leaves the golem idle.
    if ! command grep -F -e 'golem-handoff-relaunch.sh relaunch' "$skills/orchestrate/monitor-protocol.md" >/dev/null 2>&1; then
        command echo "monitor-protocol.md: no relaunch step for a HANDOFF DUE golem"
        bad=1
    fi
    return "$bad"
}

REAL_SKILLS="$REPO_ROOT/plugins/workflow/skills"

test_real_tree_passes() {
    local out rc=0
    out="$(check_tree "$REAL_SKILLS")" || rc=$?
    assert_equals "0" "$rc" "every check site is present, placed, and worktree-safe"
    assert_equals "" "$out" "no violations reported"
}

# --- negative fixtures: each rule must be seen to fire ------------------------

WORK="$(command mktemp -d "${TMPDIR:-/tmp}/budget-sites.XXXXXX")"
trap 'command rm -rf "$WORK"' EXIT

# _fixture <name> — a fresh copy of the real skills tree to mutate.
_fixture() {
    command rm -rf "${WORK:?}/$1"
    command mkdir -p "$WORK/$1"
    command cp -R "$REAL_SKILLS/." "$WORK/$1/"
    command printf '%s' "$WORK/$1"
}

# _expect_fire <tree> <expected-substring> <message>
_expect_fire() {
    local out rc=0
    out="$(check_tree "$1")" || rc=$?
    assert_equals "1" "$rc" "$3 (gate exits non-zero)"
    assert_contains "$out" "$2" "$3 (names the violation)"
}

# _edit <file> <old> <new> — replace the first literal occurrence (awk index, no regex).
_edit() {
    local f="$1" tmp="$1.tmp"
    OLD="$2" NEW="$3" command awk '
        BEGIN { o = ENVIRON["OLD"]; n = ENVIRON["NEW"] }
        { i = index($0, o); if (i && !done) { $0 = substr($0, 1, i - 1) n substr($0, i + length(o)); done = 1 } print }
    ' "$f" >"$tmp" && command mv "$tmp" "$f"
}

test_fires_on_a_missing_site() {
    local t
    t="$(_fixture missing)"
    _edit "$t/ship-issue/ci-review-protocol.md" '<!-- budget-check-site: review-cycle -->' ''
    _expect_fire "$t" "site review-cycle: marked 0 times" "a dropped site is caught"
}

test_fires_on_a_duplicated_site() {
    local t
    t="$(_fixture dup)"
    command printf '\n<!-- budget-check-site: impl-done -->\n' >>"$t/golem/SKILL.md"
    _expect_fire "$t" "site impl-done: marked 2 times" "a copied site is caught"
}

test_fires_on_a_refused_spelling() {
    local t
    t="$(_fixture spelling)"
    _edit "$t/next-issue/phase2-plan.md" "$RECIPE" '${CLAUDE_PLUGIN_ROOT}/scripts/context-budget.sh check "$PWD"'
    _expect_fire "$t" "site plan-approved: block lacks the worktree-safe recipe" "a refused spelling is caught"
}

test_fires_when_impl_done_moves_after_the_handoff() {
    local t f
    t="$(_fixture order)"
    f="$t/next-issue/phase2-plan.md"
    _edit "$f" '<!-- budget-check-site: impl-done -->' ''
    command printf '\n<!-- budget-check-site: impl-done -->\n%s\nhandoff\n<!-- end-budget-check-site -->\n' "$RECIPE" >>"$f"
    _expect_fire "$t" "placement: impl-done" "a site moved past the ship hand-off is caught"
}

test_fires_without_the_unknown_report() {
    local t
    t="$(_fixture unknown)"
    _edit "$t/next-issue/handoff-protocol.md" 'context budget: UNKNOWN (exit <n>)' 'context budget: ?'
    _expect_fire "$t" "no UNKNOWN report line" "a dropped UNKNOWN line is caught"
}

test_fires_without_the_relaunch_step() {
    local t
    t="$(_fixture relaunch)"
    _edit "$t/orchestrate/monitor-protocol.md" 'golem-handoff-relaunch.sh relaunch' 'golem-status.sh'
    _expect_fire "$t" "no relaunch step" "a dropped relaunch step is caught"
}

run_test test_real_tree_passes "the real tree satisfies every check-site rule"
run_test test_fires_on_a_missing_site "a missing site fails the gate"
run_test test_fires_on_a_duplicated_site "a duplicated site fails the gate"
run_test test_fires_on_a_refused_spelling "a worktree-refused spelling fails the gate"
run_test test_fires_when_impl_done_moves_after_the_handoff "a misplaced site fails the gate"
run_test test_fires_without_the_unknown_report "a missing UNKNOWN report fails the gate"
run_test test_fires_without_the_relaunch_step "a missing relaunch step fails the gate"

generate_report
