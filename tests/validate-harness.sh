#!/usr/bin/env bash
# Self-test for the shared test harness (tests/lib/harness.sh).
#
# Every other gate trusts harness.sh's assertions, but the harness itself had no
# test — most notably assert_true's argument-parsing heuristic (the last arg is
# the failure *message* when it contains whitespace or starts with an uppercase
# letter; otherwise every arg is part of the *command*). A silent regression
# there would weaken every gate at once while the suite still reported green.
#
# Testing assertions against themselves has one wrinkle: by design every
# assert_* returns 0 even on failure — it signals via _fail (stdout) and
# TEST_STATUS, not the exit code — so a probe that is *meant* to fail cannot be
# detected by its return status, and run directly would corrupt this suite's own
# counters. So each probe runs inside a command-substitution subshell
# (capture_assert): its stdout is captured for inspection and its global
# mutations are discarded, leaving the live suite's counters/TEST_STATUS intact.
#
# Pure bash + coreutils; no external deps. Uses the harness it is testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Harness self-test"

# --- Probe helper -----------------------------------------------------------

# capture_assert <assertion> [args...]
# Run an assertion in an isolated subshell and echo whatever it wrote to stdout.
# A passing assertion writes nothing; a failing one writes its _fail block. The
# subshell isolates the assertion's global side effects (counters, TEST_STATUS)
# from the live suite, so a deliberately-failing probe here is harmless.
capture_assert() {
    ("$@") 2>&1
}

# --- assert_true heuristic --------------------------------------------------

# A last argument containing whitespace is taken as the failure message, leaving
# the command intact (here: the bare `false`, which fails and surfaces the msg).
#
# The message text alone is a weak signal — it is echoed in the "Command:" line
# too if the heuristic FAILS to strip it. Two tight discriminators prove the
# heuristic actually fired: the default message must be ABSENT (a custom message
# replaced it), and the command line must NOT carry the message text.
test_assert_true_whitespace_is_message() {
    local out
    out="$(capture_assert assert_true false "this message has spaces")"
    assert_contains "$out" "this message has spaces" \
        "whitespace last-arg is treated as the message"
    assert_not_contains "$out" "Command should succeed" \
        "the custom message replaces the default (heuristic fired)"
    assert_not_contains "$out" "false this message" \
        "the message is stripped from the evaluated command"
}

# A single-token last argument starting with an uppercase letter is also a
# message (no whitespace needed). Same tight discriminators as above.
test_assert_true_uppercase_is_message() {
    local out
    out="$(capture_assert assert_true false Uppercaseword)"
    assert_contains "$out" "Uppercaseword" \
        "uppercase-initial last-arg is treated as the message"
    assert_not_contains "$out" "Command should succeed" \
        "the custom message replaces the default (heuristic fired)"
    assert_not_contains "$out" "false Uppercaseword" \
        "the message is stripped from the evaluated command"
}

# A lowercase single-token last argument has neither trigger, so it stays part
# of the command and the default message is used.
test_assert_true_lowercase_is_command() {
    local out
    out="$(capture_assert assert_true false lowercaseword)"
    assert_contains "$out" "Command:  false lowercaseword" \
        "lowercase last-arg stays part of the evaluated command"
    assert_contains "$out" "Command should succeed" \
        "the default message is used when no message arg is detected"
}

# A succeeding command produces no failure output — and proves the message arg
# was correctly removed before eval (eval'ing `true "msg"` here would also pass,
# so pair this with the stripping checks above for full confidence).
test_assert_true_pass_is_silent() {
    local out
    out="$(capture_assert assert_true true "Should pass quietly")"
    assert_equals "" "$out" "a passing assert_true writes nothing"
}

# --- assert_equals ----------------------------------------------------------

test_assert_equals_pass_is_silent() {
    local out
    out="$(capture_assert assert_equals foo foo)"
    assert_equals "" "$out" "equal values produce no output"
}

test_assert_equals_fail_reports() {
    local out
    out="$(capture_assert assert_equals foo bar "values differ")"
    assert_contains "$out" "values differ" "custom message is shown on mismatch"
    assert_contains "$out" "Expected: 'foo'" "expected value is reported"
    assert_contains "$out" "Actual:   'bar'" "actual value is reported"
}

# --- assert_not_empty -------------------------------------------------------

test_assert_not_empty_pass_is_silent() {
    local out
    out="$(capture_assert assert_not_empty "x")"
    assert_equals "" "$out" "a non-empty value produces no output"
}

test_assert_not_empty_fail_reports() {
    local out
    out="$(capture_assert assert_not_empty "" "should have a value")"
    assert_contains "$out" "should have a value" "empty value triggers the message"
}

# --- assert_contains --------------------------------------------------------

test_assert_contains_pass_is_silent() {
    local out
    out="$(capture_assert assert_contains "hello world" "lo wo")"
    assert_equals "" "$out" "a present substring produces no output"
}

test_assert_contains_fail_reports() {
    local out
    out="$(capture_assert assert_contains "hello world" "zzz" "needle missing")"
    assert_contains "$out" "needle missing" "absent substring triggers the message"
}

# --- assert_not_contains (newly added) --------------------------------------

test_assert_not_contains_pass_is_silent() {
    local out
    out="$(capture_assert assert_not_contains "hello world" "zzz")"
    assert_equals "" "$out" "an absent substring produces no output"
}

test_assert_not_contains_fail_reports() {
    local out
    out="$(capture_assert assert_not_contains "hello world" "lo wo" "needle present")"
    assert_contains "$out" "needle present" "present substring triggers the message"
    assert_contains "$out" "Unexpected: 'lo wo'" "the unexpected substring is reported"
}

# --- assert_valid_json (newly added) ----------------------------------------

# Well-formed JSON passes silently — the whole point of the helper is that a
# valid value produces no _fail block.
test_assert_valid_json_pass_is_silent() {
    local out
    out="$(capture_assert assert_valid_json '{"a":1}')"
    assert_equals "" "$out" "well-formed JSON produces no output"
}

# A *valid* value carrying an embedded single quote still passes silently. This
# is the footgun assert_valid_json exists to avoid: because the value arrives as
# a real argument (no eval, no re-quoting), the `'` is inert. The eval-based
# assert_true idiom — `printf '%s' '<value>' | jq ...` — would instead have this
# `'` close the surrounding single-quoted string early and let the following
# characters run as shell.
test_assert_valid_json_single_quote_value_is_safe() {
    local out
    out="$(capture_assert assert_valid_json "{\"msg\":\"it's here\"}")"
    assert_equals "" "$out" "a single quote inside valid JSON is inert (no eval)"
}

# The valid JSON scalars `false` and `null` pass silently. This pins the exact
# reason the helper uses `jq empty` (a parse-only check) over `jq -e .` (whose
# exit status keys off output *truthiness*, so `false`/`null` would be
# misreported as invalid — see the helper's doc comment in lib/harness.sh). If a
# future refactor swaps `jq empty` back for `jq -e .`, this probe fails where the
# {"a":1} case would not.
test_assert_valid_json_scalar_false_and_null_pass() {
    local out_false out_null
    out_false="$(capture_assert assert_valid_json 'false')"
    assert_equals "" "$out_false" "the valid scalar 'false' passes (jq empty, not jq -e .)"
    out_null="$(capture_assert assert_valid_json 'null')"
    assert_equals "" "$out_null" "the valid scalar 'null' passes (jq empty, not jq -e .)"
}

# Malformed JSON reports: the custom message plus the offending (truncated) value.
test_assert_valid_json_fail_reports() {
    local out
    out="$(capture_assert assert_valid_json '{bad' "not valid JSON")"
    assert_contains "$out" "not valid JSON" "malformed JSON triggers the message"
    assert_contains "$out" "Value:" "the offending value is reported"
}

# When jq is absent the helper skips (passes) — call sites already gate their
# suites on jq. Stripping PATH inside the capture subshell makes `command -v jq`
# fail, so even malformed JSON produces no output. The PATH override is confined
# to the command substitution and never touches the live suite.
test_assert_valid_json_jq_absent_skips() {
    local out
    out="$(PATH='' capture_assert assert_valid_json '{bad')"
    assert_equals "" "$out" "jq-absent path returns silently even on bad JSON"
}

# --- skip_test --------------------------------------------------------------

# skip_test mutates TESTS_SKIPPED and TEST_STATUS; run it in a subshell with
# freshly-reset state and echo the resulting values so the live counters are not
# touched.
test_skip_test_increments_counter() {
    local out
    out="$(
        TESTS_SKIPPED=0 TEST_STATUS=""
        skip_test "no reason"
        printf 'SKIPPED=%d STATUS=%s' "$TESTS_SKIPPED" "$TEST_STATUS"
    )"
    assert_contains "$out" "SKIP" "skip_test prints a SKIP marker"
    assert_contains "$out" "no reason" "skip_test prints the reason"
    assert_contains "$out" "SKIPPED=1" "skip_test increments TESTS_SKIPPED"
    assert_contains "$out" "STATUS=skipped" "skip_test sets TEST_STATUS=skipped"
}

# --- extract_contract -------------------------------------------------------
#
# extract_contract is shared infrastructure two prose-contract gates now depend
# on, and its whole value proposition is that it fails LOUD rather than handing
# back an empty region every assert_contains would then pass against. That
# vacuous-pass mode is the specific way a prose gate rots into sitting inert
# while reporting green, so the failure branches are the ones worth pinning —
# the success path is already exercised by both consuming gates on every run.
#
# Each probe builds a throwaway fixture tree under mktemp -d, so nothing here
# depends on the repo's real contract ids.

# contract_fixture <dir> <file> <body...> — write a fixture markdown file.
contract_fixture() {
    local dir="$1" name="$2"
    shift 2
    command mkdir -p "$dir"
    command printf '%s\n' "$@" >"$dir/$name"
}

test_extract_contract_happy_path() {
    local d out
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md \
        'intro line' \
        '<!-- contract: alpha -->' \
        'alpha body one' \
        'alpha body two' \
        '<!-- contract: beta -->' \
        'beta body'
    out="$(CONTRACT_SEARCH_ROOT="$d" extract_contract alpha)"
    assert_contains "$out" "alpha body one" "extract_contract: returns the block body"
    assert_not_contains "$out" "beta body" \
        "extract_contract: stops at the next marker (does not run to EOF)"
    assert_not_contains "$out" "intro line" \
        "extract_contract: starts after its own marker"
    command rm -rf "$d"
}

test_extract_contract_missing_id_fails() {
    local d rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md '<!-- contract: alpha -->' 'body'
    CONTRACT_SEARCH_ROOT="$d" extract_contract nope >/dev/null 2>&1 || rc=$?
    assert_true "[ $rc -ne 0 ]" \
        "extract_contract: a missing id exits non-zero (never an empty region)"
    command rm -rf "$d"
}

test_extract_contract_duplicate_across_files_fails() {
    local d rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md '<!-- contract: dup -->' 'body a'
    contract_fixture "$d" b.md '<!-- contract: dup -->' 'body b'
    CONTRACT_SEARCH_ROOT="$d" extract_contract dup >/dev/null 2>&1 || rc=$?
    assert_true "[ $rc -ne 0 ]" \
        "extract_contract: an id in two files exits non-zero (ambiguous target)"
    command rm -rf "$d"
}

test_extract_contract_duplicate_within_file_fails() {
    local d rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md \
        '<!-- contract: dup -->' 'first' '<!-- contract: dup -->' 'second'
    CONTRACT_SEARCH_ROOT="$d" extract_contract dup >/dev/null 2>&1 || rc=$?
    assert_true "[ $rc -ne 0 ]" \
        "extract_contract: an id twice in one file exits non-zero"
    command rm -rf "$d"
}

test_extract_contract_empty_id_fails() {
    local d rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md '<!-- contract: alpha -->' 'body'
    CONTRACT_SEARCH_ROOT="$d" extract_contract "" >/dev/null 2>&1 || rc=$?
    assert_true "[ $rc -ne 0 ]" "extract_contract: an empty id exits non-zero"
    command rm -rf "$d"
}

# A prose MENTION of the marker syntax must not act as a delimiter — the
# companion files explain these markers to their readers, and an inline mention
# that truncated a region would silently drop the tail half of a contract.
test_extract_contract_inline_mention_is_not_a_delimiter() {
    local d out
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md \
        '<!-- contract: alpha -->' \
        'before' \
        'Use the `<!-- contract: beta -->` marker to pin a block.' \
        'after'
    out="$(CONTRACT_SEARCH_ROOT="$d" extract_contract alpha)"
    assert_contains "$out" "after" \
        "extract_contract: a mid-line marker mention does not end the region"
    command rm -rf "$d"
}

# Regex-special characters in an id must be matched LITERALLY. The marker search
# is fixed-string precisely so a `+`/`(` in an id cannot be reinterpreted as a
# BRE-vs-ERE operator — the silent GNU/BSD divergence CLAUDE.md warns about,
# where the pattern stops matching and the id just reports as "not found".
test_extract_contract_regex_special_id_is_literal() {
    local d out rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md '<!-- contract: a+b(c) -->' 'special body'
    out="$(CONTRACT_SEARCH_ROOT="$d" extract_contract 'a+b(c)')" || rc=$?
    assert_true "[ $rc -eq 0 ]" \
        "extract_contract: an id with regex metacharacters resolves"
    assert_contains "$out" "special body" \
        "extract_contract: metacharacter id matches literally, not as a pattern"
    command rm -rf "$d"
}

# The other half of the mention guard. The test above proves a mid-line mention
# does not TRUNCATE a region; this proves it does not make an id RESOLVE.
#
# Both halves are needed because the two guards are separate code: `grep -rlF`
# selects files by substring (so it matches a mention), and only the awk
# `index($0, m) == 1` filter rejects it. Drop that filter and the region test
# above still passes while `extract_contract beta` starts succeeding on prose
# that never declared a contract — or, worse, counts toward a false duplicate.
test_extract_contract_mention_only_id_is_not_found() {
    local d rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md \
        '<!-- contract: alpha -->' \
        'before' \
        'Use the `<!-- contract: beta -->` marker to pin a block.' \
        'after'
    CONTRACT_SEARCH_ROOT="$d" extract_contract beta >/dev/null 2>&1 || rc=$?
    assert_true "[ $rc -ne 0 ]" \
        "extract_contract: an id only MENTIONED mid-line does not resolve"
    command rm -rf "$d"
}

# --- assert_contract_carries ------------------------------------------------

test_assert_contract_carries_present_is_silent() {
    local out
    out="$(capture_assert assert_contract_carries id 'the AGNIX_CONFIG rule' 'AGNIX_CONFIG')"
    assert_equals "" "$out" "assert_contract_carries: a present token is silent"
}

# The tamper half: an absent token must FAIL rather than pass vacuously. Without
# this probe the detector is only ever driven with tokens that are genuinely
# present, so a broken tamper check would look identical to a working one.
test_assert_contract_carries_absent_token_fails() {
    local out
    out="$(capture_assert assert_contract_carries id 'some unrelated prose' 'AGNIX_CONFIG')"
    assert_contains "$out" "FAIL" "assert_contract_carries: an absent token fails"
}

test_assert_contract_carries_empty_region_fails() {
    local out
    out="$(capture_assert assert_contract_carries id '' 'AGNIX_CONFIG')"
    assert_contains "$out" "FAIL" "assert_contract_carries: an empty region fails"
}

# --- Run all tests ----------------------------------------------------------

run_test test_assert_true_whitespace_is_message "assert_true: whitespace last-arg is the message"
run_test test_assert_true_uppercase_is_message "assert_true: uppercase-initial last-arg is the message"
run_test test_assert_true_lowercase_is_command "assert_true: lowercase last-arg stays part of the command"
run_test test_assert_true_pass_is_silent "assert_true: a passing command is silent"

run_test test_assert_equals_pass_is_silent "assert_equals: equal values are silent"
run_test test_assert_equals_fail_reports "assert_equals: mismatch reports expected/actual"

run_test test_assert_not_empty_pass_is_silent "assert_not_empty: non-empty is silent"
run_test test_assert_not_empty_fail_reports "assert_not_empty: empty reports the message"

run_test test_assert_contains_pass_is_silent "assert_contains: present substring is silent"
run_test test_assert_contains_fail_reports "assert_contains: absent substring reports the message"

run_test test_assert_not_contains_pass_is_silent "assert_not_contains: absent substring is silent"
run_test test_assert_not_contains_fail_reports "assert_not_contains: present substring reports the message"

run_test test_assert_valid_json_pass_is_silent "assert_valid_json: well-formed JSON is silent"
run_test test_assert_valid_json_single_quote_value_is_safe "assert_valid_json: single-quote value is inert (no eval)"
run_test test_assert_valid_json_scalar_false_and_null_pass "assert_valid_json: valid scalars false/null pass (jq empty)"
run_test test_assert_valid_json_fail_reports "assert_valid_json: malformed JSON reports message + value"
run_test test_assert_valid_json_jq_absent_skips "assert_valid_json: jq-absent path is silent"

run_test test_skip_test_increments_counter "skip_test: increments TESTS_SKIPPED and sets TEST_STATUS"

run_test test_extract_contract_happy_path "extract_contract: returns the marked block"
run_test test_extract_contract_missing_id_fails "extract_contract: missing id fails loud"
run_test test_extract_contract_duplicate_across_files_fails "extract_contract: id in two files fails loud"
run_test test_extract_contract_duplicate_within_file_fails "extract_contract: id twice in one file fails loud"
run_test test_extract_contract_empty_id_fails "extract_contract: empty id fails loud"
run_test test_extract_contract_inline_mention_is_not_a_delimiter "extract_contract: prose mention is not a delimiter"
run_test test_extract_contract_mention_only_id_is_not_found "extract_contract: mention-only id does not resolve"
run_test test_extract_contract_regex_special_id_is_literal "extract_contract: regex-special id matches literally"

run_test test_assert_contract_carries_present_is_silent "assert_contract_carries: present token is silent"
run_test test_assert_contract_carries_absent_token_fails "assert_contract_carries: absent token fails"
run_test test_assert_contract_carries_empty_region_fails "assert_contract_carries: empty region fails"

generate_report
