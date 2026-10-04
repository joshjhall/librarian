#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/handoff-marker.sh (issue #1058).
#
# The script is the READ side of checkpoint.handoff_marker: next-issue's Phase 0
# resume runs it first, and on an open marker it emits the R-counting directive
# so the count no longer depends on the handing-off session hand-writing one.
# Three properties carry the risk, and the cases below are grouped by them:
#
#   1. IT FAILS OPEN. A missing/empty/malformed state file, a malformed marker,
#      or an absent jq must classify and exit 0 — never error or block a resume.
#      Only a usage error (the caller's bug) is non-zero.
#
#   2. ITS "OPEN" IS THE RELAUNCH DETECTOR'S "OPEN". golem-handoff-relaunch.sh
#      keys the orchestrator's relaunch on the same classification; if the two
#      drift, the orchestrator and the resumed session disagree about whether a
#      handoff is still waiting on its count. The parity case extracts BOTH of
#      that script's jq programs and runs them over the same fixtures.
#
#   3. THE READ SITE STAYS ON THE PATH. A helper nobody calls is the #1057
#      shape (a check that is never reached errors nowhere), so the source case
#      pins the Phase 0 call in next-issue/SKILL.md.
#
# r_measured=0 is the falsy-value trap: a COUNT of zero is a measurement, not an
# open marker. `// null` only replaces null/false, so 0 must read as counted.
#
# Pure bash + coreutils via the `command` builtin; bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MARKER_SH="$REPO_ROOT/plugins/workflow/scripts/handoff-marker.sh"
RELAUNCH_SH="$REPO_ROOT/plugins/workflow/scripts/golem-handoff-relaunch.sh"
NEXT_ISSUE_SKILL="$REPO_ROOT/plugins/workflow/skills/next-issue/SKILL.md"
REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "handoff-marker.sh read side (#1058)"

jq_missing() { ! command -v jq >/dev/null 2>&1; }

WORK="$(command mktemp -d)"
trap 'command rm -rf "$WORK"' EXIT

command printf '%s\n' '{"checkpoint":{"handoff_marker":{"context_tokens":181000,"at":"2026-10-04T12:00:00Z","r_measured":null}}}' >"$WORK/open.json"
command printf '%s\n' '{"checkpoint":{"handoff_marker":{"at":"2026-10-04T12:00:00Z"}}}' >"$WORK/open-absent.json"
command printf '%s\n' '{"checkpoint":{"handoff_marker":{"at":"2026-10-04T12:00:00Z","r_measured":3}}}' >"$WORK/counted.json"
command printf '%s\n' '{"checkpoint":{"handoff_marker":{"at":"2026-10-04T12:00:00Z","r_measured":0}}}' >"$WORK/counted-zero.json"
command printf '%s\n' '{"checkpoint":{"next_action":"Begin implementation"}}' >"$WORK/none.json"
command printf '%s\n' '{"issue":1}' >"$WORK/no-checkpoint.json"
command printf '%s\n' '{"checkpoint":{"handoff_marker":"yes"}}' >"$WORK/non-object.json"
command printf '%s\n' '{"checkpoint":' >"$WORK/malformed.json"
: >"$WORK/empty.json"
# A valid document FOLLOWED by garbage: jq prints a classification for the first
# document and only then errors. Without the `|| unreadable` on the jq call, that
# partial `none` would be trusted.
command printf '%s\n' '{"checkpoint":{}} {"checkpoint":' >"$WORK/trailing-garbage.json"

# run_status <state-file> — sets RUN_OUT / RUN_RC.
run_status() {
    RUN_RC=0
    RUN_OUT="$("$REAL_BASH" "$MARKER_SH" status "$1" 2>&1)" || RUN_RC=$?
}

# --- fail open ----------------------------------------------------------------

test_open_marker_emits_directive() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    run_status "$WORK/open.json"
    assert_exit 0 "$RUN_RC" "an open marker exits 0"
    assert_contains "$RUN_OUT" "marker=open" "classified open"
    assert_contains "$RUN_OUT" "at=2026-10-04T12:00:00Z" "carries the marker's timestamp"
    assert_contains "$RUN_OUT" "directive=STEP 0" "emits the counting directive"
    assert_contains "$RUN_OUT" "first file-modifying request" "the directive names the freeze point"
    assert_contains "$RUN_OUT" "never reconstruct" "the directive forbids reconstruction"
}

test_absent_r_measured_is_open() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    run_status "$WORK/open-absent.json"
    assert_contains "$RUN_OUT" "marker=open" "a marker with no r_measured key is still uncounted"
}

test_counted_marker_has_no_directive() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    run_status "$WORK/counted.json"
    assert_exit 0 "$RUN_RC" "a counted marker exits 0"
    assert_equals "marker=counted" "$RUN_OUT" "classified counted, and nothing else printed"
}

test_zero_count_is_counted_not_open() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    run_status "$WORK/counted-zero.json"
    assert_equals "marker=counted" "$RUN_OUT" "r_measured=0 is a measurement, not an open marker"
}

test_no_marker_is_none() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    run_status "$WORK/none.json"
    assert_exit 0 "$RUN_RC" "no marker exits 0"
    assert_equals "marker=none" "$RUN_OUT" "a marker-less checkpoint is none"
    run_status "$WORK/no-checkpoint.json"
    assert_equals "marker=none" "$RUN_OUT" "a checkpoint-less state file is none"
}

test_non_object_marker_is_none() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    run_status "$WORK/non-object.json"
    assert_exit 0 "$RUN_RC" "a malformed marker exits 0"
    assert_equals "marker=none" "$RUN_OUT" "a non-object marker is none (relaunch detector agrees)"
}

test_unreadable_inputs_fail_open() {
    local f
    for f in malformed.json empty.json trailing-garbage.json does-not-exist.json; do
        run_status "$WORK/$f"
        assert_exit 0 "$RUN_RC" "$f exits 0 — never blocks a resume"
        assert_equals "marker=unreadable" "$RUN_OUT" "$f is classified unreadable"
    done
}

test_missing_jq_fails_open() {
    if jq_missing; then
        skip_test "jq genuinely absent — this case must force absence, not observe it"
        return 0
    fi
    local stub="$WORK/stub-bin"
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    RUN_RC=0
    RUN_OUT="$(/usr/bin/env -uBASH_ENV PATH="$stub" \
        "$REAL_BASH" "$MARKER_SH" status "$WORK/open.json" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "an absent jq exits 0 — telemetry never blocks"
    assert_equals "marker=unreadable" "$RUN_OUT" "an absent jq reads unreadable, never none"
}

test_usage_error_exits_1() {
    RUN_RC=0
    RUN_OUT="$("$REAL_BASH" "$MARKER_SH" check "$WORK/open.json" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "an unknown subcommand is a usage error"
    RUN_RC=0
    RUN_OUT="$("$REAL_BASH" "$MARKER_SH" status 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "a missing state-file arg is a usage error"
    RUN_RC=0
    RUN_OUT="$("$REAL_BASH" "$MARKER_SH" status "" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "an empty state-file arg is a usage error"
}

# --- one definition of "open" -------------------------------------------------

# Extract every `_marker="$(jq -r '` program from the relaunch detector, one per
# file, closing each with the `end` its terminating line carries.
extract_relaunch_programs() {
    command awk -v dir="$WORK" '
        /_marker="\$\(jq -r .$/ { n++; f = 1; out = dir "/relaunch-" n ".jq"; next }
        f && /^[[:space:]]*end. "\$_sf"/ { print "end" > out; close(out); f = 0; next }
        f { print > out }
        END { print n }' "$RELAUNCH_SH"
}

test_classification_matches_relaunch_detector() {
    jq_missing && {
        skip_test "jq absent"
        return 0
    }
    local n i fx theirs ours
    n="$(extract_relaunch_programs)"
    assert_equals "2" "$n" "golem-handoff-relaunch.sh carries exactly two marker reads"
    i=1
    while [ "$i" -le "$n" ]; do
        for fx in open open-absent counted counted-zero none no-checkpoint non-object; do
            theirs="$(command jq -r -f "$WORK/relaunch-$i.jq" "$WORK/$fx.json" | command cut -f1)"
            [ "$theirs" = "resumed" ] && theirs="counted"
            ours="$("$REAL_BASH" "$MARKER_SH" status "$WORK/$fx.json" | command sed -n 's/^marker=//p')"
            assert_equals "$theirs" "$ours" "relaunch read #$i and handoff-marker.sh agree on $fx"
        done
        i=$((i + 1))
    done
}

# --- the read site stays on the path -------------------------------------------

test_phase0_resume_calls_the_helper() {
    assert_file_contains "$NEXT_ISSUE_SKILL" "handoff-marker.sh status" \
        "next-issue Phase 0 resume runs the read-side helper"
    assert_file_not_contains "$NEXT_ISSUE_SKILL" 'CLAUDE_PLUGIN_ROOT}/scripts/handoff-marker.sh' \
        "the call is spelled worktree-safe, not via \${CLAUDE_PLUGIN_ROOT}"
}

run_test test_open_marker_emits_directive "an open marker emits the counting directive"
run_test test_absent_r_measured_is_open "a marker with no r_measured key is open"
run_test test_counted_marker_has_no_directive "a counted marker prints no directive"
run_test test_zero_count_is_counted_not_open "r_measured=0 is counted, not open (falsy trap)"
run_test test_no_marker_is_none "no marker / no checkpoint is none"
run_test test_non_object_marker_is_none "a non-object marker is none"
run_test test_unreadable_inputs_fail_open "malformed / empty / trailing-garbage / missing state files fail open"
run_test test_missing_jq_fails_open "an absent jq fails open (absence forced, not observed)"
run_test test_usage_error_exits_1 "usage errors are the only non-zero exit"
run_test test_classification_matches_relaunch_detector "classification matches golem-handoff-relaunch.sh"
run_test test_phase0_resume_calls_the_helper "Phase 0 resume calls the helper, worktree-safe"

generate_report
