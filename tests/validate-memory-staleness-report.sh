#!/usr/bin/env bash
# Behavior gate for bin/memory-staleness-report.sh — the scheduled, time-driven
# half of the OKF bundle check — and for the clock pin that moved staleness out
# of tests/validate-okf-bundle.sh.
#
# Every case injects OKF_TODAY and plants its own bundle, so nothing here reads
# the real clock: a staleness test pinned to the real date stops testing what it
# claims once the date rolls past its fixture (the exact failure that started
# this, on 2026-10-31).
#
#   nothing due                         -> 0, "No memory is expired"
#   one past stale_after                -> 1, named under Expired
#   one inside the window               -> 1, named under Expiring, NOT Expired
#   stale_after == today                -> Expiring (scanner is strict `<`)
#   stale_after == today + window       -> Expiring (horizon is inclusive)
#   stale_after == today + window + 1   -> 0 (just outside)
#   status: deprecated only             -> 0 (a FILE property: the gate's job)
#   stale_check text                    -> never printed (CI-log disclosure)
#   bad date / absent scanner           -> 2, never 0
#   the commit-time gate                -> green on an expired memory by
#                                          default; red with OKF_TODAY set
#   leap-year arithmetic                -> window crosses Feb 29 correctly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

REPORT="$REPO_ROOT/bin/memory-staleness-report.sh"
GATE="$SCRIPT_DIR/validate-okf-bundle.sh"

test_suite "memory staleness reporter + clock-free OKF gate"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# make_bundle <varname> — fresh non-git bundle (find fallback; corpus = what
# the case plants).
make_bundle() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/bundle.XXXXXX")"
    : >"$dir/MEMORY.md"
    printf -v "$__out" '%s' "$dir"
}

# memory <bundle> <name> <frontmatter-extra-lines> — an indexed reference
# memory, so the only finding a case can produce is the one it plants.
memory() {
    local b="$1" n="$2" extra="$3"
    command printf -- '---\nname: %s\ndescription: d\ntype: reference\n%b---\n\nBody.\n' \
        "$n" "$extra" >"$b/$n.md"
    command printf -- '- [%s](%s.md) — d\n' "$n" "$n" >>"$b/MEMORY.md"
}

OUT=""
RC=0
run_report() {
    local b="$1" today="$2"
    shift 2
    RC=0
    OUT="$(OKF_TODAY="$today" OKF_BUNDLE_ROOT="$b" bash "$REPORT" "$@" 2>&1)" || RC=$?
}

test_nothing_due_exits_zero() {
    local b
    make_bundle b
    memory "$b" fresh 'stale_after: 2027-06-01\nstale_check: "x"\n'
    run_report "$b" 2026-11-09
    assert_equals "0" "$RC" "nothing due within 30d exits 0"
    assert_contains "$OUT" "No memory is expired" "the clean verdict is stated"
}

test_expired_is_named_and_fails() {
    local b
    make_bundle b
    memory "$b" old 'stale_after: 2026-10-31\nstale_check: "x"\n'
    run_report "$b" 2026-11-09
    assert_equals "1" "$RC" "an expired memory fails the scheduled run"
    assert_contains "$OUT" "Expired (1)" "it is bucketed as expired"
    assert_contains "$OUT" "old.md" "the file is named"
    assert_not_contains "$OUT" "Expiring" "an expired memory is not ALSO listed as expiring"
}

test_inside_window_is_expiring_not_expired() {
    local b
    make_bundle b
    memory "$b" soon 'stale_after: 2026-11-20\nstale_check: "x"\n'
    run_report "$b" 2026-11-09
    assert_equals "1" "$RC" "an expiring memory fails the run (noticed BEFORE it expires)"
    assert_contains "$OUT" "Expiring within 30 days (1)" "it is bucketed as expiring"
    assert_not_contains "$OUT" "Expired (" "and not as expired"
}

test_window_boundaries() {
    local b
    make_bundle b
    memory "$b" ontoday 'stale_after: 2026-11-09\n'
    run_report "$b" 2026-11-09 --window 0
    assert_contains "$OUT" "Expiring within 0 days (1)" "stale_after == today is expiring (scanner is strict <)"

    make_bundle b
    memory "$b" edge 'stale_after: 2026-12-09\n'
    run_report "$b" 2026-11-09
    assert_equals "1" "$RC" "stale_after == today + window is inside (inclusive horizon)"

    make_bundle b
    memory "$b" past 'stale_after: 2026-12-10\n'
    run_report "$b" 2026-11-09
    assert_equals "0" "$RC" "stale_after == today + window + 1 is outside"
}

test_window_crosses_a_leap_day() {
    local b
    make_bundle b
    # 2028-02-01 + 29d = 2028-03-01 only if Feb 29 is counted.
    memory "$b" leap 'stale_after: 2028-03-01\n'
    run_report "$b" 2028-02-01 --window 29
    assert_equals "1" "$RC" "a 29-day window from 2028-02-01 reaches 2028-03-01"
    run_report "$b" 2028-02-01 --window 28
    assert_equals "0" "$RC" "and a 28-day window does not"
}

test_deprecated_is_left_to_the_gate() {
    local b
    make_bundle b
    memory "$b" dep 'status: deprecated\n'
    run_report "$b" 2026-11-09
    assert_equals "0" "$RC" "status: deprecated is not time-driven; the reporter ignores it"
}

test_stale_check_text_is_never_printed() {
    local b
    make_bundle b
    memory "$b" leaky 'stale_after: 2020-01-01\nstale_check: "PLANTEDCANARYSTRING"\n'
    run_report "$b" 2026-11-09
    assert_contains "$OUT" "leaky.md" "the finding is reported"
    assert_not_contains "$OUT" "PLANTEDCANARYSTRING" "but the memory's stale_check text is not"
}

test_unrunnable_scan_exits_two() {
    local b
    make_bundle b
    run_report "$b" 2026-02-30
    assert_equals "2" "$RC" "an impossible date fails loud with 2, never 0"
    run_report "$b" not-a-date
    assert_equals "2" "$RC" "a malformed date fails loud with 2"
    RC=0
    OUT="$(OKF_TODAY=2026-11-09 OKF_BUNDLE_ROOT="$b" \
        OKF_BUNDLE_SCANNER="$WORKDIR/no-such-scanner.sh" bash "$REPORT" 2>&1)" || RC=$?
    assert_equals "2" "$RC" "an absent scanner fails loud with 2, never 0"
    # A scanner that EXISTS but fails: its empty stdout must not read as clean.
    command printf '#!/usr/bin/env bash\necho boom >&2\nexit 3\n' >"$WORKDIR/broken-scanner.sh"
    RC=0
    OUT="$(OKF_TODAY=2026-11-09 OKF_BUNDLE_ROOT="$b" \
        OKF_BUNDLE_SCANNER="$WORKDIR/broken-scanner.sh" bash "$REPORT" 2>&1)" || RC=$?
    assert_equals "2" "$RC" "a failing scanner fails loud with 2, never a clean 0"
    assert_contains "$OUT" "boom" "and its stderr is surfaced"
    run_report "$b" 2026-11-09 --window -3
    assert_equals "1" "$RC" "a negative window is a usage error"
}

# THE ROOT-CAUSE PIN. Without this case the clock pin in validate-okf-bundle.sh
# could be deleted and every other assertion here would stay green.
test_commit_time_gate_ignores_the_clock() {
    local b base rc
    make_bundle b
    memory "$b" old 'stale_after: 2020-01-01\nstale_check: "x"\n'
    base="$WORKDIR/baseline"
    command printf '# empty\n' >"$base"

    rc=0
    env -uOKF_TODAY OKF_BUNDLE_ROOT="$b" OKF_BUNDLE_BASELINE="$base" \
        bash "$GATE" >"$WORKDIR/g1" 2>&1 || rc=$?
    assert_equals "0" "$rc" "the gate passes an expired memory by default — its verdict is the tree's, not the date's"

    rc=0
    OKF_TODAY=2026-11-09 OKF_BUNDLE_ROOT="$b" OKF_BUNDLE_BASELINE="$base" \
        bash "$GATE" >"$WORKDIR/g2" 2>&1 || rc=$?
    assert_equals "1" "$rc" "an explicit OKF_TODAY still gets a dated verdict (the pin is a default, not a mute)"

    make_bundle b
    memory "$b" dep 'status: deprecated\n'
    rc=0
    env -uOKF_TODAY OKF_BUNDLE_ROOT="$b" OKF_BUNDLE_BASELINE="$base" \
        bash "$GATE" >"$WORKDIR/g3" 2>&1 || rc=$?
    assert_equals "1" "$rc" "status: deprecated still fails the gate — it is written by a commit"
}

run_test test_nothing_due_exits_zero "nothing due -> 0"
run_test test_expired_is_named_and_fails "expired -> 1, bucketed and named"
run_test test_inside_window_is_expiring_not_expired "inside the window -> expiring, not expired"
run_test test_window_boundaries "window boundaries match the scanner's strict comparison"
run_test test_window_crosses_a_leap_day "pure-bash date math counts Feb 29"
run_test test_deprecated_is_left_to_the_gate "status: deprecated is the gate's, not the reporter's"
run_test test_stale_check_text_is_never_printed "no memory content reaches the CI log"
run_test test_unrunnable_scan_exits_two "an unrunnable scan exits 2, never 0"
run_test test_commit_time_gate_ignores_the_clock "validate-okf-bundle.sh's verdict is clock-free by default"

generate_report
