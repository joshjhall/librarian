#!/usr/bin/env bash
# ship-issue non-lossy split verification gate (issue #695, AC8).
#
# A reviewer that suggests a decomposition is cheap to ignore; a reviewer that
# suggests one AND can PROVE the split lost nothing is cheap to accept. That
# proof is split-verify.{py,sh}, and this gate pins its four checks:
#
#   1. LOC CONSERVATION       — content moved, not dropped
#   2. UNIT PRESERVATION      — every top-level unit survives
#   3. FAN-IN RESOLUTION      — no call site left dangling
#   4. MARKDOWN REACHABILITY  — a moved heading is still linked
#
# EVERY CHECK IS PAIRED WITH ITS COUNTER-FIXTURE. A verifier that always reports
# "verified" and one that always reports "lost" are equally useless, and a suite
# that only exercises one direction cannot tell them apart. So each property has
# a lossy fixture that MUST fire and a sound fixture that MUST stay silent, over
# the same shape of split — the fixture pair differs only in the defect.
#
# The markdown pair is the sharpest instance and the one the issue calls out as
# easiest to get wrong: the SAME content is moved out in both cases, and the only
# difference is whether a one-line pointer was left behind. A check that merely
# noticed "content moved" would pass both and prove nothing.
#
# Every case runs against BOTH the Python primary and the bash fallback
# (SPLIT_VERIFY_FORCE_BASH=1), with parity asserted per case.
#
# MUTATION-VERIFIED. Each check was proven tested by breaking it and confirming
# this gate goes red, then reverting:
#   unit preservation  — the `lost` set forced empty        -> unit case red
#   loc conservation   — tolerance raised past the drop     -> loc case red
#   md reachability    — link scan forced to "found"        -> md case red
#   md reachability    — moved-heading set forced empty     -> md case red
#
# Pure bash + coreutils; no node/jq. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

VERIFY_SH="$REPO_ROOT/plugins/workflow/skills/ship-issue/split-verify.sh"
VERIFY_PY="$REPO_ROOT/plugins/workflow/skills/ship-issue/split-verify.py"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

test_suite "ship-issue non-lossy split verification (#695 AC8)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

# run_verify ORIGINAL POST_ORIGINAL [RESULTS...] — run BOTH impls, leaving output
# in the GLOBAL `VERIFY_OUT` and parity in `VERIFY_PARITY`.
#
# A GLOBAL, not an echo: command substitution would run this in a subshell, where
# a failed assertion flips a TEST_STATUS that dies with the child and never
# reaches the parent's counters — an inert check is indistinguishable from a
# passing one. (This is not hypothetical; the sibling sizing suite shipped that
# bug and the mutation round caught it.)
run_verify() {
    local py_out
    VERIFY_PARITY="ok"
    VERIFY_OUT="$(SPLIT_VERIFY_FORCE_BASH=1 command bash "$VERIFY_SH" "$@" 2>&1 || true)"
    if [ "$HAVE_PY" = "1" ]; then
        py_out="$(command python3 "$VERIFY_PY" "$@" 2>&1 || true)"
        [ "$VERIFY_OUT" = "$py_out" ] || VERIFY_PARITY="drift"
        VERIFY_PY_OUT="$py_out"
    fi
}

assert_parity() {
    [ "$HAVE_PY" = "1" ] || return 0
    if [ "$VERIFY_PARITY" != "ok" ]; then
        _fail "bash and python impls disagree (parity drift)" \
            "The TSV contract is the language boundary — a port is a drop-in only while the output matches." \
            "bash: $VERIFY_OUT" "python: $VERIFY_PY_OUT"
    fi
}

# --- fixtures ----------------------------------------------------------------
# One original, split three ways: soundly, with a unit dropped, and with a large
# chunk dropped. Built once so every case below splits the SAME original — the
# fixtures differ only in the defect under test.
setup_code_fixtures() {
    ORIG="$WORKDIR/orig.py"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n\n'
        command printf 'def parse_body(x):\n    return x + 3\n\n'
        command printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
    } >"$ORIG"

    # Sound: the parse_* family moved out, the original keeps render_all and
    # imports what it moved.
    KEPT="$WORKDIR/kept.py"
    {
        command printf 'from parse import parse_entry, parse_header, parse_body\n\n'
        command printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
    } >"$KEPT"
    MOVED="$WORKDIR/parse.py"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n\n'
        command printf 'def parse_body(x):\n    return x + 3\n'
    } >"$MOVED"

    # Lossy: parse_body never made it into the destination file.
    LOSSY="$WORKDIR/parse-lossy.py"
    {
        command printf 'def parse_entry(x):\n    return x + 1\n\n'
        command printf 'def parse_header(x):\n    return x + 2\n'
    } >"$LOSSY"
}

setup_md_fixtures() {
    MD_ORIG="$WORKDIR/doc.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n\n'
        command printf '## Configuration\n\nConfig details here.\n\n'
        command printf '## Troubleshooting\n\nTrouble details here.\n'
    } >"$MD_ORIG"

    # The destination both markdown cases move content INTO — identical in both,
    # so the only variable is the pointer left behind.
    MD_DETAIL="$WORKDIR/doc-detail.md"
    {
        command printf '# Details\n\n'
        command printf '## Configuration\n\nConfig details here.\n\n'
        command printf '## Troubleshooting\n\nTrouble details here.\n'
    } >"$MD_DETAIL"

    # BAD: content moved out, no link left behind — the content is lost, not
    # decomposed.
    MD_BAD="$WORKDIR/doc-bad.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n'
    } >"$MD_BAD"

    # GOOD: same move, plus the one-line pointer that makes it progressive
    # disclosure rather than deletion.
    MD_GOOD="$WORKDIR/doc-good.md"
    {
        command printf '# Guide\n\nIntro text.\n\n'
        command printf '## Installation\n\nInstall steps here.\n\n'
        command printf 'See [Details](doc-detail.md) for configuration and troubleshooting.\n'
    } >"$MD_GOOD"
}

# --- check 2: unit preservation ----------------------------------------------
test_lost_unit_is_detected() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$LOSSY"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-unit-lost" "a dropped top-level unit is reported"
    assert_contains "$VERIFY_OUT" "parse_body" "the report NAMES the unit that went missing"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a lossy split is not reported as verified"
}

test_sound_split_verifies() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$MOVED"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-verified" "a sound split is reported as non-lossy"
    assert_not_contains "$VERIFY_OUT" "split-unit-lost" "a sound split reports no lost units"
    assert_not_contains "$VERIFY_OUT" "split-fanin-dangling" "a sound split reports no dangling callers"
}

# --- check 1: LOC conservation -----------------------------------------------
# Uses a LARGE drop so the loss clears the boilerplate tolerance — the tolerance
# exists precisely so a few import/mod/__init__ lines are not reported as drift.
test_loc_drift_is_detected() {
    local orig="$WORKDIR/big-orig.py" kept="$WORKDIR/big-kept.py" moved="$WORKDIR/big-moved.py" i
    : >"$orig"
    i=0
    while [ "$i" -lt 100 ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$orig"
        i=$((i + 1))
    done
    command printf 'from moved import unit_0\n' >"$kept"
    # Only the first 10 units survive: ~180 production LOC dropped, far past the
    # 40-line default tolerance.
    : >"$moved"
    i=0
    while [ "$i" -lt 10 ]; do
        command printf 'def unit_%d(x):\n    return x + %d\n' "$i" "$i" >>"$moved"
        i=$((i + 1))
    done

    run_verify "$orig" "$kept" "$moved"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-loc-drift" "a large content drop is reported as LOC drift"
    assert_contains "$VERIFY_OUT" "production LOC" "the evidence quantifies the loss"
}

# --- the tolerance is real: boilerplate does NOT trip the LOC check ----------
# Without this, the LOC check could be a bare equality test and the previous case
# would still pass — while every real split (which adds imports) reported drift.
test_boilerplate_does_not_trip_loc_check() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$MOVED"
    assert_parity
    assert_not_contains "$VERIFY_OUT" "split-loc-drift" \
        "import/re-export boilerplate does not count as lost content"
}

# --- check 4: markdown reachability ------------------------------------------
# THE pair the issue calls out. Same content moved in both; only the pointer
# differs. A check that merely noticed "content moved" would pass both.
test_unreachable_moved_heading_is_detected() {
    setup_md_fixtures
    run_verify "$MD_ORIG" "$MD_BAD" "$MD_DETAIL"
    assert_parity
    assert_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "prose moved out with no link left behind is reported"
    assert_contains "$VERIFY_OUT" "Configuration" "the report NAMES an unreachable heading"
    assert_not_contains "$VERIFY_OUT" "split-verified" "a lossy prose split is not verified"
}

test_linked_moved_heading_passes() {
    setup_md_fixtures
    run_verify "$MD_ORIG" "$MD_GOOD" "$MD_DETAIL"
    assert_parity
    assert_not_contains "$VERIFY_OUT" "split-heading-unreachable" \
        "a one-line pointer makes the moved content reachable (progressive disclosure)"
    assert_contains "$VERIFY_OUT" "split-verified" "a sound prose split is reported as non-lossy"
}

# --- the TSV contract --------------------------------------------------------
test_tsv_contract_is_five_columns() {
    setup_code_fixtures
    run_verify "$ORIG" "$KEPT" "$MOVED"
    local line cols
    assert_not_empty "$VERIFY_OUT" "there is output to check the shape of"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cols="$(command printf '%s' "$line" | command awk -F'\t' '{print NF}')"
        assert_equals "5" "$cols" "row has exactly 5 tab-separated columns"
    done <<EOF
$VERIFY_OUT
EOF
}

# --- usage contract ----------------------------------------------------------
test_usage_contract() {
    local rc=0
    command bash "$VERIFY_SH" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "no arguments exits 1"

    setup_code_fixtures
    rc=0
    command bash "$VERIFY_SH" "$ORIG" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a single argument (no results) exits 1"

    rc=0
    command bash "$VERIFY_SH" "$ORIG" "$WORKDIR/nope.py" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a missing result file exits 1"
}

run_test test_lost_unit_is_detected "Check 2: a dropped top-level unit is detected and named"
run_test test_sound_split_verifies "Check 2 counter: a sound split verifies clean"
run_test test_loc_drift_is_detected "Check 1: a large content drop is detected as LOC drift"
run_test test_boilerplate_does_not_trip_loc_check "Check 1 counter: re-export boilerplate is tolerated"
run_test test_unreachable_moved_heading_is_detected "Check 4: prose moved with no link left behind is detected"
run_test test_linked_moved_heading_passes "Check 4 counter: a one-line pointer makes the move sound"
run_test test_tsv_contract_is_five_columns "Output honors the 5-column TSV contract"
run_test test_usage_contract "Usage / missing-file contract"

generate_report
