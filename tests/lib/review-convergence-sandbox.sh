# shellcheck shell=bash
# Shared fixtures for the review-convergence test fragments
# (issue #1130 — extracted from tests/validate-review-convergence.sh).
#
# Sourced by tests/validate-review-convergence.sh BEFORE its area fragments
# under tests/review-convergence/. Holds only what two or more fragments use:
# the FIXTURES dir with every result-JSON fixture, and the finding / val
# helpers. A single-area helper (drive_loop) stays in its fragment.

# shellcheck disable=SC2034  # FIXTURES is read by the area fragments

# --- Sandbox ---------------------------------------------------------------
# One temp dir holds the result-JSON fixtures. Every fixture is written once,
# here, so a case can only differ from its sibling in the flags it passes —
# which is what makes the C3/C4 pair a real differential (see the header note).

FIXTURES="$(command mktemp -d)"
trap 'command rm -rf "$FIXTURES"' EXIT

# finding <file> <line> <category> <disposition_rule> — one finding object.
finding() {
    command printf '{"file":"%s","line_start":%s,"category":"%s","disposition_rule":"%s","title":"t"}' \
        "$1" "$2" "$3" "$4"
}

# ZERO — a cycle that found nothing. The C3/C4 pair's shared input.
command printf '{"blocking":[],"deferrable":[],"clean":true}\n' >"$FIXTURES/zero.json"

# NOVEL — one real defect in new code.
command printf '{"blocking":[%s],"deferrable":[]}\n' \
    "$(finding "src/a.js" 10 correctness R8-defect-in-new-code)" >"$FIXTURES/novel.json"

# SECOND — a DIFFERENT real defect (distinct fingerprint from novel.json).
command printf '{"blocking":[%s],"deferrable":[]}\n' \
    "$(finding "src/b.js" 20 correctness R8-defect-in-new-code)" >"$FIXTURES/second.json"

# REFUTED — every finding was re-scored LOW by the fresh judge (#555 cycle 3).
command printf '{"blocking":[],"deferrable":[%s,%s]}\n' \
    "$(finding "src/c.js" 30 correctness R2-low-certainty)" \
    "$(finding "src/d.js" 40 tests R2-low-certainty)" >"$FIXTURES/refuted.json"

# MIXED-REFUTED — one refuted finding plus one live one. Must NOT stop: C5
# requires ALL findings refuted, and this pins that it is not "any".
command printf '{"blocking":[%s],"deferrable":[%s]}\n' \
    "$(finding "src/e.js" 50 correctness R8-defect-in-new-code)" \
    "$(finding "src/c.js" 30 correctness R2-low-certainty)" >"$FIXTURES/mixed-refuted.json"

# RECURSIVE — findings about test machinery the previous fix added (#498 cycle 4).
command printf '{"blocking":[%s],"deferrable":[]}\n' \
    "$(finding "tests/foo_test.sh" 5 tests R8-defect-in-new-code)" >"$FIXTURES/recursive.json"

# MIXED-DUPLICATE — a repeat of novel.json's finding PLUS a genuinely new one.
# Must NOT stop: C6 requires ALL findings duplicated. Without this fixture a C6
# of "any duplicate" survives the suite (caught by mutation testing), and that
# mutant stops the loop on the exact cycle that just surfaced a new defect.
command printf '{"blocking":[%s,%s],"deferrable":[]}\n' \
    "$(finding "src/a.js" 10 correctness R8-defect-in-new-code)" \
    "$(finding "src/b.js" 20 correctness R8-defect-in-new-code)" >"$FIXTURES/mixed-duplicate.json"

# MIXED-RECURSIVE — test machinery plus a live source defect. Must NOT stop.
command printf '{"blocking":[%s,%s],"deferrable":[]}\n' \
    "$(finding "tests/foo_test.sh" 5 tests R8-defect-in-new-code)" \
    "$(finding "src/a.js" 10 correctness R8-defect-in-new-code)" >"$FIXTURES/mixed-recursive.json"

# The delta the previous cycle's own fix produced.
command printf 'tests/foo_test.sh\nsrc/fix.js\n' >"$FIXTURES/delta-files.txt"

# A delta that does NOT contain the test file — the same recursive finding must
# then read as novel, proving C7 keys off delta membership and not merely "the
# path looks like a test".
command printf 'src/fix.js\n' >"$FIXTURES/delta-files-nontest.txt"

# NO-SIGNAL — the cycle died before any dimension ran (#616). This is what
# `emptyResult(..., noReviewSignal=true)` emits on the manifest-failure path:
# zero findings AND `clean: false`, which is exactly why the zero must not be
# read as convergence. Distinct from zero.json ONLY in the flag, so a detector
# that ignores it returns the same verdict for both.
command printf '{"blocking":[],"deferrable":[],"clean":false,"no_review_signal":true}\n' \
    >"$FIXTURES/no-signal.json"

# NO-SIGNAL-FALSE — the same shape with the flag explicitly false. The C0b
# partner fixture: pairs with no-signal.json differing in one boolean.
command printf '{"blocking":[],"deferrable":[],"clean":true,"no_review_signal":false}\n' \
    >"$FIXTURES/no-signal-false.json"

# NEXT-SCOPE-DEFERRABLE — findings, but none blocking (#656). This is the shape
# of PR #655 cycle 1, and it is the fixture that separates `next_scope`'s real
# rule ("blocking forces another cycle") from the plausible-but-wrong "any
# findings mean narrow": it has material, so it is NOT zero.json, yet nothing
# about it obliges a further cycle. Paired against novel.json, which differs only
# in which bucket its finding sits in.
#
# Named `next-scope-` rather than the obvious `deferrable-only`: that name is
# already taken by a fixture `test_deferrable_findings_count_as_material` writes
# MID-SUITE (it is the only test here that does), so sharing it would make these
# cases depend on `run_test` registration order — every other fixture is written
# once, up front, precisely so order is free.
command printf '{"blocking":[],"deferrable":[%s],"clean":true}\n' \
    "$(finding "src/f.js" 60 tests R4-improvement)" >"$FIXTURES/next-scope-deferrable.json"

# NO-SIGNAL-WITH-BLOCKING — a harness that died PARTWAY: one dimension posted a
# finding, then the run wiped out. `no_review_signal` is true AND `blocking[]` is
# non-empty. The bucket rule alone would answer `narrow` here; the crash branch
# must win. Without this fixture the crash case is only ever seen with empty
# buckets, where both rules agree and the branch is untested.
command printf '{"blocking":[%s],"deferrable":[],"clean":false,"no_review_signal":true}\n' \
    "$(finding "src/g.js" 70 correctness R8-defect-in-new-code)" \
    >"$FIXTURES/no-signal-with-blocking.json"

# NO-BLOCKING-KEY — a result document that omits `blocking` entirely. Pins
# blocking_count()'s `// []` default, which its comment documents but which every
# other fixture hides by always writing an explicit `"blocking":[]`. A comment
# asserting behavior no test exercises is the shape that hides a defect.
command printf '{"deferrable":[]}\n' >"$FIXTURES/no-blocking-key.json"

# NO-SIGNAL-STRING — the flag as the STRING "false". jq truthiness would read
# this as no-signal and stop charging the cycle cap; the script requires a
# literal boolean `true`, so this must behave as an ordinary cycle.
command printf '{"blocking":[],"deferrable":[],"no_review_signal":"false"}\n' \
    >"$FIXTURES/no-signal-string.json"

# val <key> <output> — echo the value of a `key=value` line from the script's
# stdout. Keeps assertions terse and independent of line order.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}
