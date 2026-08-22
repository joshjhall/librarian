#!/usr/bin/env bash
# Unit coverage for lint-agnix-clean.sh's pure helpers (issues #738, #739).
#
# tests/lint-agnix-clean.sh (#734) carries three pure functions that its own six
# gate tests exercise only INDIRECTLY, and only at whatever version the host
# happens to have:
#
#   agnix_ver_lt <a> <b>   numeric major.minor.patch compare, behind the 0.48.1
#                          floor — it decides whether the gate RUNS AT ALL, so a
#                          wrong answer silently converts a real assertion into a
#                          skip (the inert-but-green failure the 77-sentinel
#                          convention exists to prevent).
#   agnix_pin_in <file>    extracts the `agnix@X.Y.Z` npm pin from a workflow
#                          file, feeding the pin-drift cross-check.
#   agnix_files_checked    reads `files_checked` from agnix `--format json` on
#                          stdin, feeding the corpus-reach floor (#739). The gate
#                          treats an empty result as a hard failure and a numeric
#                          one as the verdict, so a wrong answer either reddens a
#                          healthy tree or — worse — floats a scan that walked
#                          almost nothing over the floor.
#
# The first two were hand-verified during #734's review across 11 comparator
# cases (major/minor/patch boundaries, equality, and the multi-digit pairs
# `0.9.0` vs `0.10.0` and `2.0.0` vs `10.0.0`) and found CORRECT. So for those
# this is a coverage gap, not a latent defect — the tests pin behaviour that is
# already right, so that a future rewrite cannot quietly regress it.
#
# WHY EXTRACT RATHER THAN SOURCE. validate-threshold-check.sh can `source` its
# library because threshold-check.sh is a pure function collection with no
# top-level side effects. lint-agnix-clean.sh is the opposite: sourcing it runs
# `agnix`, prints a suite header, and `exit`s. And COPYING the two functions in
# here would be worse than no test — the copy would pass forever while the
# original drifted, which is the same-output-different-intent trap the
# bash<->python parity gate already has to guard against.
#
# So each helper's REAL body is sliced out of the gate file and eval'd, the way
# tests/lib/extract-helpers.mjs evaluates only the pure prefix of a workflow.js
# harness. The functions under test are therefore the exact bytes that ship.
#
# The extractor FAILS LOUD rather than yielding an empty region every assertion
# would then vacuously pass against — see load_fn below.
#
# Pure bash + coreutils, reached via the `command` builtin. Uses the shared
# harness assertions. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/lint-agnix-clean.sh"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "lint-agnix-clean.sh helpers (#738, #739)"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- Extraction --------------------------------------------------------------

# extract_fn <name> [file] — print the source of the named shell function as it
# appears in [file] (default $GATE): from its `name() {` signature at column 0
# through the matching `}`, also at column 0.
#
# The file is a real ARGUMENT rather than an env-var prefix on the call
# (`GATE=x extract_fn f`). A var-assignment prefix on a FUNCTION call persists
# after the call in POSIX mode while bash's default mode restores it — so the
# prefix form would silently repoint every later extraction at a fixture on one
# host and not another. Not a risk worth carrying to save a parameter.
#
# Column-0 anchoring on BOTH delimiters is what makes the slice reliable here:
# every function in the gate is top-level, and its body is indented, so a nested
# brace can never be mistaken for the terminator.
#
# `index($0, x) == 1` rather than a regex: the name is a literal, and building a
# pattern from it would mean escaping it — where a backslash-escaped char means
# opposite things in BRE and ERE across GNU and BSD. Same reasoning as
# harness.sh's extract_contract, and the same reason this repo bans GNU-only
# regex outright.
extract_fn() {
    command awk -v sig="$1() {" '
        index($0, sig) == 1 { grab = 1 }
        grab { print }
        grab && $0 == "}" { exit }
    ' "${2:-$GATE}"
}

# load_fn <name> [file] — extract the named function from [file] (default $GATE),
# verify the slice is sound, and define it in THIS shell.
#
# Two fail-loud checks, because each corresponds to a way this file could
# otherwise sit green while testing nothing:
#
#   1. EMPTY REGION — the function was renamed or deleted. Without this, eval ""
#      succeeds, the function stays undefined, and every later call fails with a
#      confusing "command not found" instead of naming the real cause.
#   2. OVER-GROWN REGION — the closing `}` was indented or moved, so the slice
#      ran past it and swallowed whatever followed. This needs its own check
#      precisely because it is the SILENT half of the pair: a moved START
#      delimiter yields an empty region and trips (1) loudly, while a moved END
#      delimiter just quietly absorbs more code. Detected by a second `() {`
#      signature inside the region.
#
# Deliberately NOT a third "is it defined after eval?" backstop. That branch
# would be UNREACHABLE, and an unreachable guard is worse than none: it invites a
# test that cannot fail, which reads as coverage. Verified — a region that passes
# (1) and (2) either evals cleanly, in which case bash has by definition defined
# the single function whose signature it carries, or is malformed and `eval`
# itself exits non-zero, aborting the suite under `set -e` before any such check
# could run. Both arms are already covered.
#
# These are hard `return 1`s under `set -e`, aborting the suite, rather than
# assertions: there is nothing meaningful left to test once extraction is broken.
load_fn() {
    local name="$1" src="${2:-$GATE}" body sig_count
    body="$(extract_fn "$name" "$src")"

    if [ -z "$body" ]; then
        command printf 'load_fn: FATAL — function "%s" not found in %s\n' "$name" "$src" >&2
        command printf '  Looked for a column-0 signature: %s() {\n' "$name" >&2
        command printf '  It was renamed, deleted, or re-indented. Restore the signature\n' >&2
        command printf '  rather than deleting this coverage.\n' >&2
        return 1
    fi

    # A well-formed region holds exactly ONE function signature: its own.
    sig_count="$(command printf '%s\n' "$body" | command grep -cE '^[[:alnum:]_]+\(\) \{' || true)"
    if [ "$sig_count" -ne 1 ]; then
        command printf 'load_fn: FATAL — extracted region for "%s" holds %s signatures\n' \
            "$name" "$sig_count" >&2
        command printf '  The closing brace is not at column 0, so the slice over-grew into\n' >&2
        command printf '  following code. Unlike a missing signature, this failure is silent\n' >&2
        command printf '  by nature — it is caught here on purpose.\n' >&2
        return 1
    fi

    # The region is the repo's OWN committed source — the same bytes shellcheck
    # already lints and run-all.sh already executes — so eval'ing it introduces
    # no input a plain `bash tests/lint-agnix-clean.sh` does not already run.
    eval "$body"
}

load_fn agnix_ver_lt
load_fn agnix_pin_in
load_fn agnix_files_checked

# The extraction guards above are load-bearing, so they get their own assertions
# rather than only ever running as invisible preconditions. Both drive the real
# extract_fn against a synthetic gate-shaped fixture.
test_extraction_guards_are_real() {
    local shape

    # A region whose closing brace is indented over-grows into the next
    # function — the silent case (2) above.
    shape="$WORKDIR/overgrown.sh"
    {
        command printf 'first_fn() {\n'
        command printf '    echo hi\n'
        command printf '    }\n' # indented — not a column-0 terminator
        command printf 'second_fn() {\n'
        command printf '    echo bye\n'
        command printf '}\n'
    } >"$shape"

    local got
    got="$(extract_fn first_fn "$shape")"
    assert_contains "$got" "second_fn() {" \
        "an indented closing brace really does let the slice run into the next function"

    local sig_count
    sig_count="$(command printf '%s\n' "$got" | command grep -cE '^[[:alnum:]_]+\(\) \{' || true)"
    assert_equals "2" "$sig_count" \
        "the over-grown region carries 2 signatures — which is exactly what load_fn rejects"

    # And the ordinary case slices cleanly.
    got="$(extract_fn second_fn "$shape")"
    assert_contains "$got" "echo bye" "a well-formed function extracts its body"
    assert_not_contains "$got" "first_fn" "extraction does not reach backwards"

    # A name that is not present yields nothing — case (1).
    got="$(extract_fn no_such_fn "$shape")"
    assert_equals "" "$got" "an absent function yields an empty region (which load_fn rejects)"
}

# load_fn's guards must REJECT the regions above — asserted by driving the real
# load_fn, not by re-describing it.
#
# The over-grown case is the one that needs proving rather than assuming. Its
# region is SYNTACTICALLY VALID: the indented `}` still closes first_fn, and the
# slice ends at second_fn's column-0 brace — so a bare `eval` succeeds silently
# and defines an EXTRA function nobody asked for. Verified out-of-tree. Nothing
# downstream would notice, which is exactly why the count check exists and why
# neutering it must fail a test rather than pass green.
#
# load_fn returns non-zero on rejection and the suite runs under `set -e`, so
# each call is `if`-guarded — a bare call would abort the test body before its
# assertion ran. stderr is captured so the diagnostic is asserted too: a guard
# that fires with an unhelpful message sends the next reader hunting.
test_load_fn_rejects_unsound_regions() {
    local shape="$WORKDIR/overgrown.sh" rc err

    {
        command printf 'first_fn() {\n'
        command printf '    echo hi\n'
        command printf '    }\n'
        command printf 'second_fn() {\n'
        command printf '    echo bye\n'
        command printf '}\n'
    } >"$shape"

    rc=0
    err="$(load_fn first_fn "$shape" 2>&1 >/dev/null)" || rc=$?
    assert_equals "1" "$rc" "load_fn rejects an over-grown region rather than eval'ing it"
    assert_contains "$err" "over-grew" "the rejection explains WHY (over-grown slice)"

    rc=0
    err="$(load_fn no_such_fn "$shape" 2>&1 >/dev/null)" || rc=$?
    assert_equals "1" "$rc" "load_fn rejects an absent function"
    assert_contains "$err" "not found" "the rejection names the missing function"

    # And the sound case still loads: a guard that rejected EVERYTHING would
    # satisfy both assertions above while making the whole file untestable.
    rc=0
    if load_fn second_fn "$shape" >/dev/null 2>&1; then rc=0; else rc=1; fi
    assert_equals "0" "$rc" "a well-formed function still loads (the guards are not blanket-reject)"
    assert_equals "bye" "$(second_fn)" "the loaded function is callable and correct"
}

# --- agnix_ver_lt ------------------------------------------------------------

# ver_lt_says <a> <b> — "yes" when agnix_ver_lt reports a < b, else "no".
#
# The `if` wrapper is MANDATORY, not stylistic. agnix_ver_lt signals its answer
# through the exit status, so a bare `agnix_ver_lt 1.0.0 1.0.0` returns 1 and,
# under this file's `set -e`, aborts the suite mid-test. Verified: the gate's own
# two call sites are both `if`-guarded for the same reason.
ver_lt_says() {
    if agnix_ver_lt "$1" "$2"; then
        command printf 'yes\n'
    else
        command printf 'no\n'
    fi
}

# assert_ver_lt <a> <b> <expected yes|no> — one row of the matrix.
assert_ver_lt() {
    assert_equals "$3" "$(ver_lt_says "$1" "$2")" \
        "agnix_ver_lt $1 $2 -> $3"
}

test_ver_lt_major() {
    assert_ver_lt 0.48.1 1.0.0 yes
    assert_ver_lt 1.0.0 0.48.1 no
    assert_ver_lt 1.9.9 2.0.0 yes
    assert_ver_lt 2.0.0 1.9.9 no
}

test_ver_lt_minor() {
    assert_ver_lt 0.47.0 0.48.0 yes
    assert_ver_lt 0.48.0 0.47.0 no
    # Minor decides even when the patch field points the other way — the whole
    # point of comparing field by field rather than as a whole.
    assert_ver_lt 0.47.9 0.48.0 yes
    assert_ver_lt 0.48.0 0.47.9 no
}

test_ver_lt_patch() {
    assert_ver_lt 0.48.0 0.48.1 yes
    assert_ver_lt 0.48.1 0.48.0 no
    assert_ver_lt 0.48.1 0.48.10 yes
}

test_ver_lt_equality() {
    # Equality is NOT less-than at every field — the boundary the floor check
    # sits on. An off-by-one here makes the gate skip at exactly the pinned
    # version, which is the version CI always runs.
    assert_ver_lt 0.48.1 0.48.1 no
    assert_ver_lt 0.0.0 0.0.0 no
    assert_ver_lt 10.10.10 10.10.10 no
}

# THE cases a lexicographic rewrite fails. `sort -V` is banned here (GNU-only;
# BSD sort on macOS lacks it), so the next person to touch this may reach for a
# string compare — under which "0.9.0" sorts AFTER "0.48.1" and "2.0.0" after
# "10.0.0", inverting both answers. Every other row above passes unchanged under
# a string compare, so without these three rows the rewrite lands green.
test_ver_lt_multi_digit_defeats_string_compare() {
    assert_ver_lt 0.9.0 0.10.0 yes
    assert_ver_lt 0.10.0 0.9.0 no
    assert_ver_lt 0.9.0 0.48.1 yes
    assert_ver_lt 0.48.1 0.9.0 no
    assert_ver_lt 2.0.0 10.0.0 yes
    assert_ver_lt 10.0.0 2.0.0 no
    # Multi-digit in the patch field too.
    assert_ver_lt 0.48.9 0.48.10 yes
    assert_ver_lt 0.48.10 0.48.9 no
}

# The comparator's answer for the repo's ACTUAL pin/floor pair. This is the
# question the gate asks in production, so pin it against live inputs rather than
# only synthetic ones — read from the files, never hardcoded, so bumping the pin
# does not mean editing this file.
test_ver_lt_on_the_live_pin_and_floor() {
    local pin floor
    pin="$(command grep -oE 'agnix@[0-9]+\.[0-9]+\.[0-9]+' "$WORKFLOW_DIR/ci.yml" |
        command head -n 1 | command sed -n 's/^agnix@//p')"
    floor="$(command sed -n 's/^AGNIX_MIN_VERSION="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
        "$GATE" | command head -n 1)"

    assert_not_empty "$pin" "the CI pin is readable (else this test proves nothing)"
    assert_not_empty "$floor" "the gate's floor literal is readable"

    # pin < floor would mean the gate SKIPS in CI forever. lint-agnix-clean.sh
    # asserts this too (test_floor_not_stale); asserting it here as well is
    # deliberate — that one proves the gate reaches the right verdict, this one
    # proves the comparator underneath it does.
    assert_equals "no" "$(ver_lt_says "$pin" "$floor")" \
        "CI's agnix pin ($pin) is not below the gate floor ($floor)"
}

# --- agnix_pin_in ------------------------------------------------------------

# write_workflow <path> <line...> — a throwaway file with the given lines.
write_workflow() {
    local path="$1"
    shift
    local line
    : >"$path"
    for line in "$@"; do
        command printf '%s\n' "$line" >>"$path"
    done
}

test_pin_in_extracts_a_present_pin() {
    local f="$WORKDIR/present.yml"
    # The real line shape from ci.yml / code-scanning.yml — the pin is mid-line,
    # inside an `if`, with a `&&` after it. A pattern anchored to line start, or
    # one that swallowed the trailing text, would fail here and pass on a
    # simplified fixture.
    write_workflow "$f" \
        "      - name: Install agnix" \
        "        run: |" \
        "          if npm install -g agnix@0.49.0 && agnix --version; then"
    assert_equals "0.49.0" "$(agnix_pin_in "$f")" \
        "the version is extracted from a real-shaped install line"
}

test_pin_in_absent_pin_is_empty_not_fatal() {
    local f="$WORKDIR/absent.yml"
    write_workflow "$f" "steps:" "  - run: echo no agnix here"
    assert_equals "" "$(agnix_pin_in "$f")" "a file with no pin yields an empty string"
}

# The `|| true` inside agnix_pin_in is load-bearing and its own comment says so —
# so assert it, rather than trusting the comment. A comment claiming a property
# the code lacks is worse than no comment.
#
# Verified out-of-tree: with the `|| true` removed, this exact call under
# `set -euo pipefail` kills the caller with rc=1 before any assertion runs. The
# gate would then die with a bare status, reporting nothing about WHY.
test_pin_in_no_match_survives_pipefail() {
    local f="$WORKDIR/absent2.yml" rc=0 out
    write_workflow "$f" "nothing to see"

    # A child shell with the SAME options the gate runs under. Sourcing this
    # file's already-eval'd function is not possible across the boundary, so the
    # child re-extracts it the same way — keeping the assertion on real bytes.
    out="$(GATE="$GATE" "$(command -v bash)" -c '
        set -euo pipefail
        eval "$(command awk -v sig="agnix_pin_in() {" '"'"'
            index($0, sig) == 1 { grab = 1 }
            grab { print }
            grab && $0 == "}" { exit }
        '"'"' "$GATE")"
        V="$(agnix_pin_in "$1")"
        printf "survived:[%s]\n" "$V"
    ' _ "$f")" || rc=$?

    assert_equals "0" "$rc" \
        "a no-match extraction does not abort a set -euo pipefail caller (the || true is doing its job)"
    assert_equals "survived:[]" "$out" \
        "the caller reaches its next statement with an empty value"
}

test_pin_in_rejects_a_malformed_pin() {
    local f="$WORKDIR/malformed.yml"
    # Two fields, not three. Must NOT match: both call sites feed the result
    # straight to agnix_ver_lt, whose own contract note says callers must pass a
    # three-field numeric version. A loosened regex here would push a malformed
    # value into the comparator, where `${v##*.}` and `${v%%.*}` would both
    # yield the same field and the compare would be quietly nonsense.
    write_workflow "$f" "          if npm install -g agnix@0.49 && agnix --version; then"
    assert_equals "" "$(agnix_pin_in "$f")" "a two-field version is not a pin"

    # A bare package name with no version at all.
    write_workflow "$f" "          if npm install -g agnix && agnix --version; then"
    assert_equals "" "$(agnix_pin_in "$f")" "an unpinned install line yields nothing"
}

test_pin_in_takes_the_first_of_several() {
    local f="$WORKDIR/several.yml"
    # The contract is "the FIRST pin" (head -n 1). If a workflow ever grows a
    # second install line, the cross-check must compare a deterministic one.
    write_workflow "$f" \
        "          if npm install -g agnix@0.49.0 && agnix --version; then" \
        "          npm install -g agnix@0.50.0"
    assert_equals "0.49.0" "$(agnix_pin_in "$f")" "the first pin wins, deterministically"
}

test_pin_in_missing_file_is_empty_not_fatal() {
    local rc=0 got
    # The gate calls this on two hardcoded workflow paths. If one is renamed, the
    # helper must yield empty so test_pins_found reports the real problem — not
    # die on a bare grep error.
    got="$(agnix_pin_in "$WORKDIR/does-not-exist.yml")" || rc=$?
    assert_equals "0" "$rc" "a missing file does not abort the caller"
    assert_equals "" "$got" "a missing file yields an empty pin"
}

# --- agnix_files_checked -----------------------------------------------------

# The corpus-reach floor (#739) rests entirely on this extraction: an empty
# result is a hard gate failure, and a WRONG one silently changes the verdict.
# It runs on hosts with no agnix at all — which is the point, since the gate
# itself skips there and would otherwise leave the parser untested exactly where
# nobody is watching.

# A real-shaped agnix `--format json` payload: the field sits at the top level,
# pretty-printed, followed by the diagnostics array. Fixtures are built from the
# shape agnix actually emits (verified against 0.49.0) rather than a minimal
# `{"files_checked":N}`, so a pattern that only works on the simplified form
# cannot pass here.
agnix_json_fixture() {
    command printf '%s\n' \
        '{' \
        '  "version": "0.49.0",' \
        "  \"files_checked\": ${1:-110}," \
        '  "diagnostics": [' \
        '    {' \
        '      "level": "warning",' \
        '      "rule": "CC-MEM-006",' \
        '      "file": "CLAUDE.md",' \
        '      "line": 126,' \
        '      "message": "Negative instruction without positive alternative"' \
        '    }' \
        '  ],' \
        '  "summary": { "errors": 0, "warnings": 80, "info": 1 }' \
        '}'
}

test_files_checked_extracts_from_real_shape() {
    assert_equals "110" "$(agnix_json_fixture 110 | agnix_files_checked)" \
        "the count is extracted from a real-shaped agnix JSON payload"

    # A different value, so the test cannot pass by coincidence against a
    # hardcoded 110 anywhere in the pipeline.
    assert_equals "7" "$(agnix_json_fixture 7 | agnix_files_checked)" \
        "the extracted value tracks the payload, not a constant"

    # Multi-digit and zero both parse — zero especially, since it is the exact
    # value the gate must be able to see in order to FAIL on an empty scan. An
    # extractor that returned empty for 0 would send the gate down the
    # unparsable/broken-environment branch instead of the floor assertion.
    assert_equals "0" "$(agnix_json_fixture 0 | agnix_files_checked)" \
        "a zero count parses as \"0\", not as an empty/unparsable result"
}

test_files_checked_tolerates_compact_json() {
    # Same JSON, no pretty-printing. agnix pretty-prints today, but the pattern
    # must not depend on the whitespace around the colon — that is formatting,
    # not contract.
    assert_equals "42" "$(command printf '%s' '{"version":"0.49.0","files_checked":42,"diagnostics":[]}' | agnix_files_checked)" \
        "a compact payload with no space after the colon still parses"

    # And extra whitespace on both sides.
    assert_equals "42" "$(command printf '%s' '{ "files_checked"  :   42 }' | agnix_files_checked)" \
        "extra whitespace around the colon still parses"
}

test_files_checked_absent_field_is_empty_not_fatal() {
    local rc=0 got
    # agnix that ran but emitted no such field. Must yield empty so the gate's
    # fail-loud branch reports the real problem, rather than dying on a bare
    # grep error mid-substitution.
    got="$(command printf '%s' '{"version":"0.49.0","diagnostics":[]}' | agnix_files_checked)" || rc=$?
    assert_equals "0" "$rc" "an absent field does not abort the caller"
    assert_equals "" "$got" "an absent field yields an empty count"

    # Completely empty input — the shape of a crashed agnix whose stderr was
    # dropped, which is precisely how the gate invokes it.
    rc=0
    got="$(command printf '%s' '' | agnix_files_checked)" || rc=$?
    assert_equals "0" "$rc" "empty input does not abort the caller"
    assert_equals "" "$got" "empty input yields an empty count"
}

# The `|| true` inside agnix_files_checked is load-bearing and its own comment
# says so — so assert it against real bytes rather than trusting the comment,
# exactly as test_pin_in_no_match_survives_pipefail does for the sibling helper.
test_files_checked_no_match_survives_pipefail() {
    local rc=0 out

    out="$(GATE="$GATE" "$(command -v bash)" -c '
        set -euo pipefail
        eval "$(command awk -v sig="agnix_files_checked() {" '"'"'
            index($0, sig) == 1 { grab = 1 }
            grab { print }
            grab && $0 == "}" { exit }
        '"'"' "$GATE")"
        V="$(printf "%s" "{\"diagnostics\":[]}" | agnix_files_checked)"
        printf "survived:[%s]\n" "$V"
    ')" || rc=$?

    assert_equals "0" "$rc" \
        "a no-match extraction does not abort a set -euo pipefail caller (the || true is doing its job)"
    assert_equals "survived:[]" "$out" \
        "the caller reaches its next statement with an empty value"
}

test_files_checked_rejects_a_malformed_value() {
    # A non-numeric value must NOT be accepted. The gate feeds the result
    # straight to `[ "$FILES_CHECKED" -ge "$AGNIX_MIN_FILES" ]`, where a
    # non-numeric operand is a bash syntax error that aborts the test function
    # before its assertion runs — the check would vanish rather than fail. An
    # empty result instead routes to the fail-loud branch, which is correct.
    assert_equals "" "$(command printf '%s' '{"files_checked": "many"}' | agnix_files_checked)" \
        "a quoted non-numeric value is not accepted as a count"

    assert_equals "" "$(command printf '%s' '{"files_checked": null}' | agnix_files_checked)" \
        "a null value is not accepted as a count"

    # A negative number: the minus is not consumed by the pattern, so this must
    # not silently yield a positive 12 that would sail over the floor.
    local got
    got="$(command printf '%s' '{"files_checked": -12}' | agnix_files_checked)"
    local is_twelve=0
    if [ "$got" = "12" ]; then
        is_twelve=1
    fi
    assert_equals "0" "$is_twelve" \
        "a negative value is not silently read as its positive magnitude"
}

test_files_checked_ignores_lookalike_text_in_messages() {
    # The two-stage grep-then-sed exists so a `files_checked`-shaped substring
    # inside a diagnostic MESSAGE cannot be mistaken for the real field. The
    # real field here is 110; a message mentions a different number.
    local payload
    payload='{"files_checked": 110, "diagnostics": [{"message": "expected files_checked: 999 in config"}]}'
    assert_equals "110" "$(command printf '%s' "$payload" | agnix_files_checked)" \
        "the top-level field wins over a lookalike inside a message (first match)"
}

# --- Registration ------------------------------------------------------------

run_test test_extraction_guards_are_real "Extraction guards catch an over-grown / absent region"
run_test test_load_fn_rejects_unsound_regions "load_fn rejects unsound regions, accepts sound ones"

run_test test_ver_lt_major "agnix_ver_lt: major field decides"
run_test test_ver_lt_minor "agnix_ver_lt: minor field decides"
run_test test_ver_lt_patch "agnix_ver_lt: patch field decides"
run_test test_ver_lt_equality "agnix_ver_lt: equality is not less-than"
run_test test_ver_lt_multi_digit_defeats_string_compare \
    "agnix_ver_lt: multi-digit fields compare numerically, not lexically"
run_test test_ver_lt_on_the_live_pin_and_floor "agnix_ver_lt: live CI pin vs gate floor"

run_test test_pin_in_extracts_a_present_pin "agnix_pin_in: extracts a real-shaped pin"
run_test test_pin_in_absent_pin_is_empty_not_fatal "agnix_pin_in: absent pin yields empty"
run_test test_pin_in_no_match_survives_pipefail "agnix_pin_in: no-match survives set -euo pipefail"
run_test test_pin_in_rejects_a_malformed_pin "agnix_pin_in: malformed version is not a pin"
run_test test_pin_in_takes_the_first_of_several "agnix_pin_in: first pin wins"
run_test test_pin_in_missing_file_is_empty_not_fatal "agnix_pin_in: missing file yields empty"

run_test test_files_checked_extracts_from_real_shape \
    "agnix_files_checked: extracts the count from a real-shaped payload"
run_test test_files_checked_tolerates_compact_json \
    "agnix_files_checked: whitespace around the colon is formatting, not contract"
run_test test_files_checked_absent_field_is_empty_not_fatal \
    "agnix_files_checked: absent field / empty input yields empty"
run_test test_files_checked_no_match_survives_pipefail \
    "agnix_files_checked: no-match survives set -euo pipefail"
run_test test_files_checked_rejects_a_malformed_value \
    "agnix_files_checked: non-numeric value is not a count"
run_test test_files_checked_ignores_lookalike_text_in_messages \
    "agnix_files_checked: a lookalike inside a message does not win"

generate_report
