# shellcheck shell=bash
# Charged / warn — budgeting the terminator (#1120) — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- charged / warn: budget the terminator (#1120) ---------------------------
#
# #1057 (PR #1112): a clean narrow cycle (C3) consumed cycle 4, the full cycle 5
# found a blocking defect, and C1 stopped the loop with its fix unreviewed.
# `charged` stops C3 spending the cap; `warn` flags the full cycle that will be
# the final word BEFORE it runs.

# The exact boundary AC#1 demands: cycle+1 == max warns, cycle+2 == max does
# not. next-scope-deferrable.json is a continue (C8) whose next_scope is full.
test_warn_fires_exactly_when_the_next_full_cycle_is_the_last() {
    local at_boundary one_early
    at_boundary="$("$RC" check --cycle 4 --max-cycles 5 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 500)"
    one_early="$("$RC" check --cycle 3 --max-cycles 5 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 500)"
    assert_equals "continue" "$(val verdict "$at_boundary")" "the boundary case continues"
    assert_equals "full" "$(val next_scope "$at_boundary")" "and its next cycle is full"
    assert_equals "final-full-review" "$(val warn "$at_boundary")" \
        "cycle + 1 == max with next_scope=full warns"
    assert_equals "" "$(val warn "$one_early")" "cycle + 2 == max does not warn"
}

test_warn_needs_a_full_next_scope_and_a_continue() {
    local narrow stopped
    # Same boundary, but a blocking finding: the next cycle is narrow, so it is
    # not a candidate terminator and the warning would be noise.
    narrow="$("$RC" check --cycle 4 --max-cycles 5 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "narrow" "$(val next_scope "$narrow")" "a blocking cycle advises narrow"
    assert_equals "" "$(val warn "$narrow")" "a narrow next cycle does not warn"
    # A stop has no next cycle at all.
    stopped="$("$RC" check --cycle 4 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 500)"
    assert_equals "stop" "$(val verdict "$stopped")" "a clean full cycle stops"
    assert_equals "" "$(val warn "$stopped")" "a stop does not warn"
}

# After an UNCHARGED cycle the retry reuses the same number, so the boundary is
# cycle == max, not cycle + 1. Each case would come out wrong under a rule that
# always adds one.
test_warn_accounts_for_an_uncharged_cycle() {
    local crashed narrow_zero
    crashed="$("$RC" check --cycle 5 --max-cycles 5 --attempt 6 --max-attempts 10 \
        --result "$FIXTURES/no-signal.json" --delta-lines 0)"
    assert_equals "false" "$(val charged "$crashed")" "a crashed cycle is uncharged"
    assert_equals "final-full-review" "$(val warn "$crashed")" \
        "a crash at cycle == max warns — its full retry is the final cycle"
    # The #1057 shape: an uncharged C3 at cycle 4 of 5 leaves TWO reviewed
    # cycles, so the full cycle after it is not the last one.
    narrow_zero="$("$RC" check --cycle 4 --max-cycles 5 --attempt 6 \
        --result "$FIXTURES/zero.json" --delta-lines 39 --prev-delta-lines 500)"
    assert_equals "C3-narrow-zero" "$(val rule "$narrow_zero")" "the narrow clean cycle is C3"
    assert_equals "false" "$(val charged "$narrow_zero")" "and it is uncharged"
    assert_equals "" "$(val warn "$narrow_zero")" "so the next full cycle is not the last — no warning"
}

# The attempt cap can end the loop before the cycle cap — more often now that
# C3 spends attempts without cycles — and that final trip is just as final.
# Each case is far from the CYCLE boundary, so only the attempt arm can warn.
test_warn_fires_when_the_attempt_cap_binds_first() {
    local crashed deferrable early
    crashed="$("$RC" check --cycle 3 --max-cycles 5 --attempt 5 --max-attempts 6 \
        --result "$FIXTURES/no-signal.json" --delta-lines 0)"
    assert_equals "final-full-review" "$(val warn "$crashed")" \
        "a crash whose retry is the last ATTEMPT warns, though cycle 3 is far from 5"
    deferrable="$("$RC" check --cycle 2 --max-cycles 5 --attempt 5 --max-attempts 6 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 500)"
    assert_equals "final-full-review" "$(val warn "$deferrable")" \
        "a full-next continue at attempt max-1 warns"
    early="$("$RC" check --cycle 2 --max-cycles 5 --attempt 4 --max-attempts 6 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 500)"
    assert_equals "" "$(val warn "$early")" "attempt max-2 does not warn"
}

# One case per structurally distinct path, the early-exit ones (C0, C0b) included.
test_warn_is_emitted_on_every_verdict() {
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_contains "$out" "warn=" "warn is emitted on the C1-cap path"
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 500)"
    assert_contains "$out" "warn=" "warn is emitted on a C4 stop"
    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 10 --max-attempts 10 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_contains "$out" "warn=" "warn is emitted on the C0-attempt-cap path"
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/no-signal.json" --delta-lines 0)"
    assert_contains "$out" "warn=" "warn is emitted on the C0b path"
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 500 --partial true)"
    assert_contains "$out" "warn=" "warn is emitted on the C2-partial path"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" --delta-lines 500)"
    assert_contains "$out" "warn=" "warn is emitted on the C5 path"
}

# ANTI-TAUTOLOGY pair: identical C3 calls differing ONLY in whether --attempt was
# passed. Without --attempt it defaults to --cycle, so an uncharged cycle would
# freeze both counters and C0 could never fire — the unmigrated caller must keep
# charging.
test_narrow_zero_is_uncharged_only_with_an_explicit_attempt() {
    local migrated unmigrated
    migrated="$("$RC" check --cycle 2 --max-cycles 5 --attempt 2 \
        --result "$FIXTURES/zero.json" --delta-lines 100 --prev-delta-lines 1000)"
    unmigrated="$("$RC" check --cycle 2 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 100 --prev-delta-lines 1000)"
    assert_equals "C3-narrow-zero" "$(val rule "$migrated")" "the migrated call is C3"
    assert_equals "C3-narrow-zero" "$(val rule "$unmigrated")" "the unmigrated call is C3"
    assert_equals "false" "$(val charged "$migrated")" "C3 with --attempt is uncharged"
    assert_equals "true" "$(val charged "$unmigrated")" "C3 without --attempt stays charged"
    # An EMPTY --attempt value also falls back to --cycle, so it must read as
    # absent: keying the guard on the flag's presence would un-charge C3 here
    # while both counters stay frozen.
    local empty
    empty="$("$RC" check --cycle 2 --max-cycles 5 --attempt "" \
        --result "$FIXTURES/zero.json" --delta-lines 100 --prev-delta-lines 1000)"
    assert_equals "C3-narrow-zero|true" "$(val rule "$empty")|$(val charged "$empty")" \
        "an empty --attempt keeps C3 charged"
}

test_every_other_rule_is_charged() {
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 1 --result "$FIXTURES/zero.json" --delta-lines 500)"
    assert_equals "C4-zero|true" "$(val rule "$out")|$(val charged "$out")" "C4 is charged"
    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 1 --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "C8-novel|true" "$(val rule "$out")|$(val charged "$out")" "C8 is charged"
    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 1 --result "$FIXTURES/zero.json" \
        --delta-lines 500 --partial true)"
    assert_equals "C2-partial|true" "$(val rule "$out")|$(val charged "$out")" "C2 is charged"
    # A C3 hidden behind the cap stays charged: the deciding rule is C1.
    out="$("$RC" check --cycle 5 --max-cycles 5 --attempt 5 --result "$FIXTURES/zero.json" \
        --delta-lines 100 --prev-delta-lines 1000)"
    assert_equals "C1-cap|C3-narrow-zero|true" \
        "$(val rule "$out")|$(val capped_over "$out")|$(val charged "$out")" \
        "a capped C3 is C1-cap and charged"
    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 10 --max-attempts 10 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "C0-attempt-cap|true" "$(val rule "$out")|$(val charged "$out")" "C0 is charged"
    out="$("$RC" check --cycle 2 --max-cycles 5 --attempt 2 --result "$FIXTURES/refuted.json" --delta-lines 500)"
    assert_equals "C5-refuted-only|true" "$(val rule "$out")|$(val charged "$out")" "C5 is charged"
    out="$("$RC" check --cycle 2 --max-cycles 5 --attempt 2 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "C6-duplicate|true" "$(val rule "$out")|$(val charged "$out")" "C6 is charged"
    out="$("$RC" check --cycle 2 --max-cycles 5 --attempt 2 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/delta-files.txt" --delta-lines 400 --prev-delta-lines 400)"
    assert_equals "C7-recursive|true" "$(val rule "$out")|$(val charged "$out")" "C7 is charged"
    # C2b is a CONTINUE, so un-charging it by analogy with C0b would let an
    # unengaged review loop on attempts alone. Its fixture is written inline here
    # rather than shared, so this case does not depend on run_test order.
    command printf '{"blocking":[],"deferrable":[],"unengaged_dimensions":["security"]}\n' \
        >"$FIXTURES/charged-unengaged.json"
    out="$("$RC" check --cycle 2 --max-cycles 5 --attempt 2 --result "$FIXTURES/charged-unengaged.json" \
        --delta-lines 400 --prev-delta-lines 400)"
    assert_equals "C2b-unengaged|true" "$(val rule "$out")|$(val charged "$out")" "C2b is charged"
    # C0b needs no --attempt to go uncharged — unlike C3 — because it was
    # uncharged before #1120 (the caller read no_review_signal itself), so this
    # only reports existing behavior rather than introducing a new uncharged path.
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/no-signal.json" --delta-lines 0)"
    assert_equals "C0b-no-signal|false" "$(val rule "$out")|$(val charged "$out")" \
        "C0b is uncharged even without --attempt"
    # An unmigrated (charged) C3 at max-1 warns — its next cycle is cycle+1 =
    # max — the reverse of the uncharged C3 at the same position above.
    out="$("$RC" check --cycle 4 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 39 --prev-delta-lines 500)"
    assert_equals "C3-narrow-zero|true|final-full-review" \
        "$(val rule "$out")|$(val charged "$out")|$(val warn "$out")" \
        "a charged C3 at max-1 warns — its next cycle is the cap"
}

# drive_loop <max-cycles> <max-attempts> <fixture,delta;...> — run the caller's
# loop as ci-review-protocol.md step (f) specifies it: attempt++ every trip,
# cycle++ only on charged=true, prev-delta carried forward. The script decides
# the next cycle's scope, so each step is "fixture,delta" where delta is the
# surface reviewed (a narrow step after a blocking cycle, a full one otherwise).
# The plan wraps when exhausted. Echoes `rule cycle attempt warns`.
drive_loop() {
    local max="$1" max_attempts="$2" plan="$3" cycle=1 attempt=1 prev="" out
    local step fixture delta rest="$3" warns=0 rule="" iterations=0
    while [ "$iterations" -lt 40 ]; do
        iterations=$((iterations + 1))
        [ -n "$rest" ] || rest="$plan"
        step="${rest%%;*}"
        case "$rest" in *\;*) rest="${rest#*;}" ;; *) rest="" ;; esac
        fixture="${step%%,*}"
        delta="${step#*,}"
        if [ -n "$prev" ]; then
            out="$("$RC" check --cycle "$cycle" --max-cycles "$max" --attempt "$attempt" \
                --max-attempts "$max_attempts" --result "$FIXTURES/$fixture.json" \
                --delta-lines "$delta" --prev-delta-lines "$prev")"
        else
            out="$("$RC" check --cycle "$cycle" --max-cycles "$max" --attempt "$attempt" \
                --max-attempts "$max_attempts" --result "$FIXTURES/$fixture.json" \
                --delta-lines "$delta")"
        fi
        rule="$(val rule "$out")"
        [ "$(val warn "$out")" = "final-full-review" ] && warns=$((warns + 1))
        [ "$(val verdict "$out")" = "stop" ] && break
        attempt=$((attempt + 1))
        [ "$(val charged "$out")" = "true" ] && cycle=$((cycle + 1))
        prev="$delta"
    done
    command printf '%s %s %s %s' "$rule" "$cycle" "$attempt" "$warns"
}

# The #1057 sequence replayed: full-blocking, narrow-blocking x2, narrow-clean,
# full-blocking, ... Under the old charging the 5th trip — a FULL review that
# blocked — was the capped one, its fix unreviewed. Now the narrow-clean trip is
# free, so the cap lands one trip later, on the narrow re-check of that fix.
test_observed_sequence_reviews_the_final_fix() {
    local res
    res="$(drive_loop 5 10 "novel,1000;second,200;novel,200;zero,39;second,1000;novel,200")"
    assert_equals "C1-cap 5 6 0" "$res" \
        "the cap lands on trip 6 (a narrow re-check), not on the full trip 5"
}

# AC#2's other half: an uncharged C3 must not make the loop unbounded. A review
# that alternates a blocking cycle and a narrow clean one forever only charges
# every second trip — REVIEW_MAX_ATTEMPTS is what stops it.
test_uncharged_narrow_zero_loop_is_bounded_by_attempts() {
    local res
    res="$(drive_loop 5 6 "novel,1000;zero,10;novel,1000;zero,10")"
    assert_equals "C0-attempt-cap" "${res%% *}" "an endless blocking/narrow-clean loop stops at C0"
    res="${res#* }"
    assert_equals "4 6" "${res% *}" "at attempt 6, having charged only 3 of 5 trips"
}
