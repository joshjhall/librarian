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

# extract_contract <id> [file] — the two-argument form scopes the search to one
# file instead of walking CONTRACT_SEARCH_ROOT. Worth its own case because the
# fixture plants the SAME id in a sibling file: under the root-walking form that
# is a fatal duplicate, so if the file argument were ignored (or fell back to a
# repo-wide search) this call would fail instead of returning the block.
test_extract_contract_explicit_file_scopes_the_search() {
    local d out rc=0
    d="$(command mktemp -d)"
    contract_fixture "$d" a.md '<!-- contract: scoped -->' 'body from a'
    contract_fixture "$d" b.md '<!-- contract: scoped -->' 'body from b'

    out="$(CONTRACT_SEARCH_ROOT="$d" extract_contract scoped "$d/a.md")" || rc=$?
    assert_true "[ $rc -eq 0 ]" \
        "extract_contract: an explicit file resolves even when the id is duplicated elsewhere"
    assert_contains "$out" "body from a" \
        "extract_contract: the explicit file's block is returned"
    assert_not_contains "$out" "body from b" \
        "extract_contract: the unsearched sibling is ignored"

    # And the contrast that proves the scoping did the work: without the file
    # argument the same fixture is a fatal duplicate.
    local rc2=0
    CONTRACT_SEARCH_ROOT="$d" extract_contract scoped >/dev/null 2>&1 || rc2=$?
    assert_true "[ $rc2 -ne 0 ]" \
        "extract_contract: the same id without a file argument is a fatal duplicate"
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

# --- assert_file_defines (#830) ---------------------------------------------
#
# The helper exists to close a hole in `assert_file_contains`, so every case
# here is written as the DIVERGENT one — an input where the old raw-grep and the
# new helper disagree. A fixture that would pass under both proves nothing, and
# is precisely the defect #830 was filed about.
#
# defines_fixture <dir> <name> <line...> — write a throwaway fixture file.
defines_fixture() {
    local dir="$1" name="$2"
    shift 2
    command mkdir -p "$dir"
    command printf '%s\n' "$@" >"$dir/$name"
}

# THE case. The old assertion greps the whole file, so the comment explaining
# the setting satisfies it with the definition deleted. Anchoring alone is not
# enough — `# SKIP=77` is still line-initial after the `#`.
test_assert_file_defines_comment_does_not_satisfy() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh \
        '# Reserved exit code meaning "did NOT run".' \
        '# SKIP_EXIT_CODE=77'
    out="$(capture_assert assert_file_defines "$d/gate.sh" SKIP_EXIT_CODE "must not be satisfied by prose")"
    assert_contains "$out" "must not be satisfied by prose" \
        "assert_file_defines: a commented-out definition does NOT satisfy it"
    # Discriminator: the old helper is green on this very fixture, so the two
    # genuinely diverge here rather than the fixture being trivially broken.
    local old
    # lint-allow-unanchored: the control arm — this MUST be the old raw-text
    # helper, since the point is that it is satisfied where the new one is not.
    old="$(capture_assert assert_file_contains "$d/gate.sh" "SKIP_EXIT_CODE=77" "raw grep")"
    assert_equals "" "$old" \
        "assert_file_defines: (control) the raw-text assertion IS satisfied by the comment"
    command rm -rf "$d"
}

test_assert_file_defines_real_definition_passes() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh \
        '# Reserved exit code meaning "did NOT run".' \
        'SKIP_EXIT_CODE=77'
    out="$(capture_assert assert_file_defines "$d/gate.sh" SKIP_EXIT_CODE)"
    assert_equals "" "$out" "assert_file_defines: a real definition passes silently"
    command rm -rf "$d"
}

# Leading indentation is legitimate (a definition inside a function or block),
# so the anchor must allow it while still rejecting mid-line occurrences.
test_assert_file_defines_indented_definition_passes() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh '    INDENTED_SETTING=1'
    out="$(capture_assert assert_file_defines "$d/gate.sh" INDENTED_SETTING)"
    assert_equals "" "$out" "assert_file_defines: an indented definition passes"
    command rm -rf "$d"
}

# A `NAME=` appearing mid-command is a USE, not a definition.
test_assert_file_defines_midline_does_not_satisfy() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh 'echo SETTING=1'
    out="$(capture_assert assert_file_defines "$d/gate.sh" SETTING "mid-line is not a definition")"
    assert_contains "$out" "mid-line is not a definition" \
        "assert_file_defines: a mid-line occurrence does NOT satisfy it"
    command rm -rf "$d"
}

# A longer name that merely CONTAINS the sought one must not satisfy it. Both
# ends are needed and they pin DIFFERENT rules:
#   PREFIX_SETTING  — pinned by the index()==1 anchor (the name is not at col 1)
#   SETTING_EXTRA   — pinned by the trailing `=` (the name IS at col 1, and only
#                     requiring `NAME=` rather than `NAME` rejects it)
# Testing only the prefix end leaves the `=` rule unexercised — found by
# mutation: dropping the `=` survived a prefix-only test.
test_assert_file_defines_prefix_does_not_satisfy() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh 'PREFIX_SETTING=1'
    out="$(capture_assert assert_file_defines "$d/gate.sh" SETTING "prefix is not the name")"
    assert_contains "$out" "prefix is not the name" \
        "assert_file_defines: PREFIX_SETTING does NOT satisfy SETTING"
    command rm -rf "$d"
}

test_assert_file_defines_longer_name_does_not_satisfy() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh 'SETTING_EXTRA=1'
    out="$(capture_assert assert_file_defines "$d/gate.sh" SETTING "a longer name is not this name")"
    assert_contains "$out" "a longer name is not this name" \
        "assert_file_defines: SETTING_EXTRA does NOT satisfy SETTING (the '=' is required)"
    command rm -rf "$d"
}

# Matching is FIXED-STRING. A `.` in the name is a literal, not any-char — the
# BSD/GNU regex divergence CLAUDE.md flags is sidestepped by never building a
# pattern. Both arms are needed: that the literal matches, and that it does not
# match what a regex would have.
test_assert_file_defines_name_is_literal_not_regex() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" a.toml 'tool.ruff=1'
    out="$(capture_assert assert_file_defines "$d/a.toml" "tool.ruff")"
    assert_equals "" "$out" "assert_file_defines: a dotted name matches literally"
    defines_fixture "$d" b.toml 'toolXruff=1'
    out="$(capture_assert assert_file_defines "$d/b.toml" "tool.ruff" "dot is not any-char")"
    assert_contains "$out" "dot is not any-char" \
        "assert_file_defines: the '.' does NOT match an arbitrary character"
    command rm -rf "$d"
}

# A NAME carrying its own `=` pins the VALUE, not just the presence. Both arms
# are needed: the right value passes, and a DIFFERENT value fails — otherwise
# the assertion would silently degrade to a presence check, which is how the
# swept call sites (pinning one sentinel across three files) would lose their
# teeth without anyone noticing.
test_assert_file_defines_value_form_pins_the_value() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh 'SKIP_EXIT_CODE=77'
    out="$(capture_assert assert_file_defines "$d/gate.sh" "SKIP_EXIT_CODE=77")"
    assert_equals "" "$out" "assert_file_defines: the pinned value passes"
    out="$(capture_assert assert_file_defines "$d/gate.sh" "SKIP_EXIT_CODE=99" "wrong value")"
    assert_contains "$out" "wrong value" \
        "assert_file_defines: a DIFFERENT value fails (the value is really pinned)"
    command rm -rf "$d"
}

# index()==1 is a PREFIX test, so the value form needs a right-hand boundary or
# a superset value satisfies the pin: `=770` would satisfy a pin of `=77`, and
# `|| exit 10` a pin of `|| exit 1` — the latter live in the swept ci.yml /
# release.yml assertion. Both were reproduced before the boundary was added.
# The earlier value test cannot catch this: it compares 77 against 99, which
# share no prefix, so it passes with and without the guard.
test_assert_file_defines_value_form_rejects_a_superset() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh 'SKIP_EXIT_CODE=770'
    out="$(capture_assert assert_file_defines "$d/gate.sh" "SKIP_EXIT_CODE=77" "770 is not 77")"
    assert_contains "$out" "770 is not 77" \
        "assert_file_defines: a LONGER value does not satisfy the pinned one"
    defines_fixture "$d" ci.yml 'ruff_version="$(bash bin/ruff-version.sh)" || exit 10'
    out="$(capture_assert assert_file_defines "$d/ci.yml" \
        'ruff_version="$(bash bin/ruff-version.sh)" || exit 1' "exit 10 is not exit 1")"
    assert_contains "$out" "exit 10 is not exit 1" \
        "assert_file_defines: '|| exit 10' does not satisfy a pin of '|| exit 1'"
    command rm -rf "$d"
}

# The boundary must tolerate what is invisible to the value: trailing whitespace
# and a `\` line continuation. Without this the guard would reject the real
# wrapped call sites it was added to protect.
test_assert_file_defines_value_form_tolerates_continuation() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh 'SKIP_EXIT_CODE=77   '
    out="$(capture_assert assert_file_defines "$d/gate.sh" "SKIP_EXIT_CODE=77")"
    assert_equals "" "$out" "assert_file_defines: trailing whitespace does not break the pin"
    defines_fixture "$d" wrapped.sh 'SKIP_EXIT_CODE=77 \'
    out="$(capture_assert assert_file_defines "$d/wrapped.sh" "SKIP_EXIT_CODE=77")"
    assert_equals "" "$out" "assert_file_defines: a trailing continuation does not break the pin"
    command rm -rf "$d"
}

# The failure must name the ACTUAL cause. A value mismatch and a commented-out
# definition are different problems with different fixes, and reporting "no
# non-comment line defines it" above a live definition sends the reader hunting
# for a commented-out one that does not exist. Both arms are asserted, since a
# diagnostic that says the same thing either way carries no information.
test_assert_file_defines_failure_distinguishes_cause() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" drift.sh 'SKIP_EXIT_CODE=770'
    out="$(capture_assert assert_file_defines "$d/drift.sh" "SKIP_EXIT_CODE=77")"
    assert_contains "$out" "not with this exact value" \
        "assert_file_defines: a live definition with a different value says so"
    assert_not_contains "$out" "no non-comment line defines it" \
        "assert_file_defines: and does NOT claim the definition is missing"
    defines_fixture "$d" commented.sh '# SKIP_EXIT_CODE=77'
    out="$(capture_assert assert_file_defines "$d/commented.sh" "SKIP_EXIT_CODE=77")"
    assert_contains "$out" "no non-comment line defines it" \
        "assert_file_defines: a commented-out definition still reports as such"
    command rm -rf "$d"
}

# The value form must still exclude comments — this is the exact shape of the
# swept call sites, and the exact defect #830 reported.
test_assert_file_defines_value_form_excludes_comments() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh \
        '# run-all.sh renders it as [SKIP].' \
        '# SKIP_EXIT_CODE=77'
    out="$(capture_assert assert_file_defines "$d/gate.sh" "SKIP_EXIT_CODE=77" "commented value")"
    assert_contains "$out" "commented value" \
        "assert_file_defines: a commented-out valued definition does NOT satisfy it"
    command rm -rf "$d"
}

test_assert_file_defines_missing_file_fails() {
    local d out
    d="$(command mktemp -d)"
    out="$(capture_assert assert_file_defines "$d/absent.sh" SETTING "missing file")"
    assert_contains "$out" "missing file" "assert_file_defines: a missing file fails"
    assert_contains "$out" "File does not exist" \
        "assert_file_defines: the missing-file failure says so explicitly"
    command rm -rf "$d"
}

# The failure block must point at the comment that would have satisfied the old
# assertion — that is the line the reader needs to see to understand the hole.
test_assert_file_defines_failure_names_the_near_miss() {
    local d out
    d="$(command mktemp -d)"
    defines_fixture "$d" gate.sh '# SKIP_EXIT_CODE=77'
    out="$(capture_assert assert_file_defines "$d/gate.sh" SKIP_EXIT_CODE)"
    assert_contains "$out" "# SKIP_EXIT_CODE=77" \
        "assert_file_defines: the failure reports the commented near-miss"
    command rm -rf "$d"
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
run_test test_extract_contract_explicit_file_scopes_the_search "extract_contract: explicit file scopes the search"

run_test test_assert_contract_carries_present_is_silent "assert_contract_carries: present token is silent"
run_test test_assert_contract_carries_absent_token_fails "assert_contract_carries: absent token fails"
run_test test_assert_contract_carries_empty_region_fails "assert_contract_carries: empty region fails"

run_test test_assert_file_defines_comment_does_not_satisfy "assert_file_defines: a commented-out definition does not satisfy (#830)"
run_test test_assert_file_defines_real_definition_passes "assert_file_defines: a real definition passes"
run_test test_assert_file_defines_indented_definition_passes "assert_file_defines: an indented definition passes"
run_test test_assert_file_defines_midline_does_not_satisfy "assert_file_defines: a mid-line use is not a definition"
run_test test_assert_file_defines_prefix_does_not_satisfy "assert_file_defines: a longer prefixed name does not satisfy"
run_test test_assert_file_defines_longer_name_does_not_satisfy "assert_file_defines: a longer suffixed name does not satisfy"
run_test test_assert_file_defines_name_is_literal_not_regex "assert_file_defines: the name matches literally, not as a regex"
run_test test_assert_file_defines_value_form_pins_the_value "assert_file_defines: a NAME=value form pins the value"
run_test test_assert_file_defines_value_form_rejects_a_superset "assert_file_defines: the value form rejects a superset value"
run_test test_assert_file_defines_failure_distinguishes_cause "assert_file_defines: the failure names value-drift vs commented-out"
run_test test_assert_file_defines_value_form_tolerates_continuation "assert_file_defines: the value form tolerates trailing space and continuation"
run_test test_assert_file_defines_value_form_excludes_comments "assert_file_defines: the value form still excludes comments"
run_test test_assert_file_defines_missing_file_fails "assert_file_defines: a missing file fails"
run_test test_assert_file_defines_failure_names_the_near_miss "assert_file_defines: the failure names the commented near-miss"

generate_report
