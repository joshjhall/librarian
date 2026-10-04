# shellcheck shell=bash
# classifiers-fragment load guard (#1109) — golem-gate-watch tests (issue #564
# split).
#
# golem-gate-watch.sh's pane classifiers live in the sourced fragment
# golem-gate-watch-classifiers.sh. These cases pin that a failed load is LOUD,
# and — the property that matters — that a SOURCING caller still takes its safe
# path rather than reading undefined matchers as "no gate".
#
# Own file rather than 30-helpers-and-modes.sh, which sat at 687 production LOC:
# this case would have pushed it over the shell warning budget.
#
# Sourced by tests/golem-gate-watch.sh, which defines GATE_WATCH and REPO_ROOT
# and sources tests/lib/gate-watch-sandbox.sh first.

# Missing classifiers fragment (#1109): the pane_is_* matchers live in a sourced
# golem-gate-watch-classifiers.sh, and a failed load must be LOUD — executed AND
# sourced. The sourced half is the one that matters: golem-handoff-relaunch.sh's
# pane_has_gate sources gate-watch and treats a load failure as "gate" (refuse).
# A silent miss would leave the matchers undefined, every `pane_is_* && return 0`
# would fall through, and an idle-looking pane would read "no gate" — the unsafe
# direction. So assert pane_has_gate's ANSWER, not just gate-watch's exit code.
test_missing_classifiers_fails_loud() {
    local tmp out rc=0 probe
    tmp="$(command mktemp -d)" || return 1
    command cp -R "$REPO_ROOT/plugins/workflow/scripts" "$tmp/scripts"
    assert_file_exists "$tmp/scripts/golem-gate-watch-classifiers.sh" \
        "Vacuity guard: the fragment exists in the copy before removal"
    command rm -f "$tmp/scripts/golem-gate-watch-classifiers.sh"

    out="$(bash "$tmp/scripts/golem-gate-watch.sh" --once-panes 2>&1)" && rc=0 || rc=$?
    assert_equals "2" "$rc" "Executed without the fragment: exits 2"
    assert_contains "$out" "cannot load" "Executed without the fragment: names the missing file"

    rc=0
    bash -c '. "$1" 2>/dev/null' _ "$tmp/scripts/golem-gate-watch.sh" && rc=0 || rc=$?
    assert_equals "2" "$rc" "Sourced without the fragment: the source itself fails"

    # pane_has_gate sliced from the real caller, run against the broken copy and
    # the intact tree. The intact run is the control: plain text is NOT a gate.
    # shellcheck disable=SC2016  # expanded by the inner bash, not here
    probe='SCRIPT_DIR="$1"
eval "$(command sed -n "/^pane_has_gate() {/,/^}/p" "$1/golem-handoff-relaunch.sh")"
pane_has_gate "plain idle text" && echo gate || echo no-gate'
    assert_equals "gate" "$(bash -c "$probe" _ "$tmp/scripts" 2>/dev/null)" \
        "handoff-relaunch's pane_has_gate refuses (gate) when the fragment is missing"
    assert_equals "no-gate" "$(bash -c "$probe" _ "$REPO_ROOT/plugins/workflow/scripts" 2>/dev/null)" \
        "Control: with the fragment present, plain text is not a gate"
    command rm -rf "$tmp"
}
