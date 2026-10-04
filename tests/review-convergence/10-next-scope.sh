# shellcheck shell=bash
# Next_scope — the re-review scope advice (#656) — review-convergence tests (issue #1130 split).
#
# Sourced by tests/validate-review-convergence.sh, which defines RC and sources
# tests/lib/review-convergence-sandbox.sh (FIXTURES / finding / val) BEFORE
# this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_fragment_test list.

# --- next_scope: the re-review scope advice (#656) ---------------------------
#
# Why this field exists: narrowing (#492) told the caller to narrow every cycle
# after the first, and C3-narrow-zero (#568) rejects a zero on a narrow surface.
# Composed, a narrowed cycle CANNOT end the loop — measured on PR #655, where
# cycle 2 cost 45k output tokens and was structurally incapable of returning
# `stop`. next_scope moves the scope decision next to the stop decision so the
# two cannot disagree.
#
# The anti-tautology discipline from the header applies here too: the
# blocking/deferrable pair below is byte-identical apart from WHICH BUCKET the
# finding sits in, so a rule that keys on finding COUNT returns the same answer
# for both and the pair cannot both pass.

test_next_scope_is_narrow_after_blocking() {
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "narrow" "$(val next_scope "$out")" \
        "a cycle with blocking findings advises narrowing (a fix must be re-checked)"
}

test_next_scope_is_full_after_clean() {
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 500)"
    assert_equals "full" "$(val next_scope "$out")" \
        "a clean cycle advises a full next surface (it is a candidate terminator)"
}

# THE case that makes the rule non-obvious, and the shape of PR #655 cycle 1:
# findings exist, so this is not the zero case, but none of them block — so
# nothing obliges another cycle and the next one must be able to terminate.
test_next_scope_is_full_after_deferrable_only() {
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 500)"
    assert_equals "full" "$(val next_scope "$out")" \
        "a deferrable-only cycle advises FULL — deferrables oblige no further cycle"
    # It must still be material for CONVERGENCE (#580) — the two questions are
    # separate, and this asserts adding next_scope did not merge them.
    assert_equals "1" "$(val findings "$out")" \
        "the deferrable still counts as material for the convergence rules"
    assert_equals "C8-novel" "$(val rule "$out")" \
        "and still reads as novel material, so the loop continues"
}

# A result may omit `blocking` altogether — blocking_count()'s `// []` default
# says that reads as zero, i.e. `full`. Without this the default is asserted only
# by a comment, and `read_findings` already tolerates the same omission, so a
# document of this shape genuinely reaches here.
# A crashed cycle advises `full` UNCONDITIONALLY — including when it managed to
# post a blocking finding before dying. What such a cycle actually reviewed is
# unknown, so narrowing the retry would review a fraction of an unknown
# remainder. The pair below is the differential: both fixtures carry one blocking
# finding and differ ONLY in `no_review_signal`, so a rule that consults just the
# bucket returns `narrow` for both and cannot pass.
test_next_scope_after_a_crash_is_always_full() {
    local crashed healthy
    crashed="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/no-signal-with-blocking.json" --delta-lines 500)"
    healthy="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"

    assert_equals "C0b-no-signal" "$(val rule "$crashed")" "the crashed fixture takes the C0b path"
    assert_equals "full" "$(val next_scope "$crashed")" \
        "a crash advises full even WITH a blocking finding (what it reviewed is unknown)"
    assert_equals "narrow" "$(val next_scope "$healthy")" \
        "the same lone blocking finding on a healthy cycle still advises narrow"

    # And the empty-bucket crash, where both rules happen to agree — asserted so
    # the two crash shapes are pinned to the same answer.
    local empty_crash
    empty_crash="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/no-signal.json" --delta-lines 500)"
    assert_equals "full" "$(val next_scope "$empty_crash")" \
        "a crash with empty buckets advises full too"
}

test_next_scope_handles_a_missing_blocking_key() {
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/no-blocking-key.json" --delta-lines 500)"
    assert_equals "full" "$(val next_scope "$out")" \
        "an absent blocking key counts as 0 blocking findings, not null"
    assert_equals "0" "$(val findings "$out")" "and the document still reads as zero findings"
    assert_equals "C4-zero" "$(val rule "$out")" "so it converges normally"
}

# The differential the anti-tautology note demands: novel.json and
# next-scope-deferrable.json each carry exactly ONE finding. They differ only in
# the bucket. A rule written as `total > 0 -> narrow` passes both preceding tests
# individually but cannot satisfy this one.
test_next_scope_keys_on_bucket_not_count() {
    local blocking_out deferrable_out
    blocking_out="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"
    deferrable_out="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 500)"

    assert_equals "1" "$(val findings "$blocking_out")" "the blocking fixture has one finding"
    assert_equals "1" "$(val findings "$deferrable_out")" "the deferrable fixture has one finding"
    # Same count, opposite advice — only a bucket-aware rule can do this.
    assert_equals "narrow" "$(val next_scope "$blocking_out")" "one BLOCKING finding -> narrow"
    assert_equals "full" "$(val next_scope "$deferrable_out")" "one DEFERRABLE finding -> full"
}

# Emitted unconditionally, like capped_over (#635), so a consumer never has to
# test for the key's presence — including on the cap paths, where the loop is
# ending and the value goes unused.
test_next_scope_emitted_on_every_verdict() {
    local out cases fixture
    # C1-cap, C0-attempt-cap, C0b-no-signal, C2-partial, C3, C4, C8 — every
    # structurally distinct path through the rule list.
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "C1-cap" "$(val rule "$out")" "cap path reached"
    assert_not_empty "$(val next_scope "$out")" "next_scope is emitted on the C1-cap path"

    out="$("$RC" check --cycle 1 --max-cycles 5 --attempt 10 --max-attempts 10 \
        --result "$FIXTURES/novel.json" --delta-lines 500)"
    assert_equals "C0-attempt-cap" "$(val rule "$out")" "attempt-cap path reached"
    assert_not_empty "$(val next_scope "$out")" "next_scope is emitted on the C0-attempt-cap path"

    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/no-signal.json" --delta-lines 500)"
    assert_equals "C0b-no-signal" "$(val rule "$out")" "no-signal path reached"
    assert_equals "full" "$(val next_scope "$out")" \
        "a crashed cycle has no blocking findings, so it advises full"

    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 500 --partial true)"
    assert_equals "C2-partial" "$(val rule "$out")" "partial path reached"
    assert_not_empty "$(val next_scope "$out")" "next_scope is emitted on the C2-partial path"

    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 100 --prev-delta-lines 1000)"
    assert_equals "C3-narrow-zero" "$(val rule "$out")" "narrow-zero path reached"
    assert_not_empty "$(val next_scope "$out")" "next_scope is emitted on the C3 path"

    # And the field is never empty on any of them — a blank would force a
    # consumer to branch on presence, which is the contract this avoids.
    for fixture in zero novel next-scope-deferrable refuted recursive; do
        cases="$("$RC" check --cycle 1 --max-cycles 5 \
            --result "$FIXTURES/$fixture.json" --delta-lines 500)"
        assert_not_empty "$(val next_scope "$cases")" \
            "next_scope is non-empty for the $fixture fixture"
    done
}

# next_scope is ADVISORY. It must not have perturbed any verdict, rule, or count
# — the loop's termination guarantee rests on the C0/C1 ordering, and a scope
# field that shifted a verdict would be a far worse bug than the one #656 fixes.
# Pins the full pre-existing output for one case per rule.
test_next_scope_changes_no_existing_verdict() {
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 500)"
    assert_equals "stop" "$(val verdict "$out")" "C4 still stops"
    assert_equals "C4-zero" "$(val rule "$out")" "C4 still decides"
    assert_equals "0" "$(val findings "$out")" "C4 counts unchanged"

    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 100 --prev-delta-lines 1000)"
    assert_equals "continue" "$(val verdict "$out")" "C3 still continues"
    assert_equals "C3-narrow-zero" "$(val rule "$out")" "C3 still decides"

    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 100 --prev-delta-lines 1000)"
    assert_equals "C1-cap" "$(val rule "$out")" "C1 still outranks the convergence rules"
    assert_equals "C3-narrow-zero" "$(val capped_over "$out")" "capped_over still reports what C1 hid"
}

# The issue's headline acceptance criterion, driven end-to-end through the real
# script: a clean cycle followed by a clean cycle must terminate in TWO cycles,
# with the second NOT narrowed. Before #656 the caller narrowed cycle 2
# unconditionally, C3 fired on its zero, and a third cycle was required — the
# exact PR #655 sequence.
test_clean_then_clean_terminates_in_two_cycles() {
    local c1 c2 scope delta2
    # Cycle 1: the real PR #655 shape — deferrable-only over the full diff.
    c1="$("$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/next-scope-deferrable.json" --delta-lines 1855)"
    assert_equals "continue" "$(val verdict "$c1")" "cycle 1 continues (novel material)"
    scope="$(val next_scope "$c1")"
    assert_equals "full" "$scope" "cycle 1 advises a FULL cycle 2"

    # Cycle 2 at the advised scope. `full` means the surface is the whole diff
    # again, so --delta-lines is comparable to cycle 1's rather than a fraction.
    delta2=1855
    c2="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines "$delta2" --prev-delta-lines 1855)"
    assert_equals "stop" "$(val verdict "$c2")" "cycle 2 TERMINATES the loop"
    assert_equals "C4-zero" "$(val rule "$c2")" \
        "and stops on genuine convergence, not the cap"

    # The counterfactual, same cycle-2 result: had it been narrowed (the pre-#656
    # behavior), C3 would have fired and a third cycle been required. This is what
    # makes the assertion above non-vacuous — it shows the scope advice, not the
    # fixture, is what produced the early stop.
    local narrowed
    narrowed="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 244 --prev-delta-lines 1855)"
    assert_equals "continue" "$(val verdict "$narrowed")" \
        "the SAME clean result on a narrowed surface would NOT have terminated"
    assert_equals "C3-narrow-zero" "$(val rule "$narrowed")" \
        "it would have fired C3 — the wasted cycle #656 removes"
}
