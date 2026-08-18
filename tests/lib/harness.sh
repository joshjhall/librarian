#!/usr/bin/env bash
# Minimal, self-contained test harness for the librarian quality gates.
#
# This is a dependency-light vendoring of just the assertion + reporting
# surface the relocated skill/agent structural gates use. It deliberately
# does NOT pull in the containers test framework (which is Docker-coupled and
# sources eight assertion modules). Everything the gates call lives here:
#
#   test_suite / run_test / generate_report   — suite + per-test tracking
#   assert_true                               — eval a command, message heuristic
#   assert_equals / assert_not_empty          — value assertions
#   assert_contains                           — substring assertion
#   assert_valid_json                         — no-eval JSON validation (untrusted-safe)
#   assert_file_exists                        — filesystem assertion
#   assert_file_contains / _not_contains      — grep-based file assertions
#   skip_test                                 — record a skipped test
#
# Semantics match the containers framework so the relocated gate bodies run
# unmodified. Pure bash + coreutils; no external deps. Full paths / the
# `command` builtin are used for coreutils per project convention.

set -euo pipefail

# --- Counters / state -------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_STATUS=""
SUITE_NAME=""

# Color output only when stdout is a TTY.
if [ -t 1 ]; then
    _C_RED=$'\033[31m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_BOLD=$'\033[1m'
    _C_RESET=$'\033[0m'
else
    _C_RED=""
    _C_GREEN=""
    _C_YELLOW=""
    _C_BOLD=""
    _C_RESET=""
fi

# --- Suite / test lifecycle -------------------------------------------------

test_suite() {
    SUITE_NAME="$1"
    printf '%s\n' "${_C_BOLD}=== ${SUITE_NAME} ===${_C_RESET}"
}

# run_test <function> <description>
# Resets per-test status, runs the function, and records pass/fail/skip.
run_test() {
    local test_func="$1"
    local test_desc="${2:-$test_func}"

    TEST_STATUS=""
    TESTS_RUN=$((TESTS_RUN + 1))

    printf '  %s ... ' "$test_desc"

    # A test body that returns non-zero without calling an assertion still
    # counts as a failure (mirrors the framework's set -e-tolerant behavior:
    # assertions flip TEST_STATUS, the return code is a backstop).
    if "$test_func"; then
        :
    else
        if [ "$TEST_STATUS" != "failed" ] && [ "$TEST_STATUS" != "skipped" ]; then
            TEST_STATUS="failed"
            printf '%s\n' "${_C_RED}FAIL${_C_RESET} (test body returned non-zero)"
        fi
    fi

    if [ "$TEST_STATUS" = "skipped" ]; then
        : # already reported by skip_test
    elif [ "$TEST_STATUS" = "failed" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf '%s\n' "${_C_GREEN}PASS${_C_RESET}"
    fi
}

# Internal: record a failing assertion. Prints details; flips TEST_STATUS.
# Only the first failure of a test prints the FAIL header so output stays
# readable; subsequent failures within the same test add detail lines.
_fail() {
    local message="$1"
    shift
    if [ "$TEST_STATUS" != "failed" ]; then
        printf '%s\n' "${_C_RED}FAIL${_C_RESET}"
        TEST_STATUS="failed"
    fi
    printf '      %s%s%s\n' "${_C_RED}" "$message" "${_C_RESET}"
    local line
    for line in "$@"; do
        printf '        %s\n' "$line"
    done
}

skip_test() {
    local reason="$1"
    printf '%s\n' "${_C_YELLOW}SKIP${_C_RESET} (${reason})"
    if [ "$TEST_STATUS" != "skipped" ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    fi
    TEST_STATUS="skipped"
}

# --- Assertions -------------------------------------------------------------

# assert_true <command...> [message]
# Evaluates the command string. The containers framework treats the last
# argument as the failure message when it contains whitespace or starts with
# an uppercase letter; we replicate that heuristic so gate bodies are portable.
assert_true() {
    local all_args=("$@")
    local last="${all_args[*]: -1}"
    local message="Command should succeed"
    local cmd

    if [[ "$last" =~ [[:space:]] ]] || [[ "$last" =~ ^[A-Z] ]]; then
        message="$last"
        # Command is everything except the last argument.
        local n=$((${#all_args[@]} - 1))
        if [ "$n" -le 0 ]; then
            cmd=""
        else
            cmd="${all_args[*]:0:$n}"
        fi
    else
        cmd="${all_args[*]}"
    fi

    if eval "$cmd" >/dev/null 2>&1; then
        return 0
    else
        _fail "$message" "Command:  $cmd"
        return 0 # do not abort the test body; one failed assertion != stop
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    if [ "$expected" = "$actual" ]; then
        return 0
    fi
    _fail "$message" "Expected: '$expected'" "Actual:   '$actual'"
    return 0
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"
    if [ -n "$value" ]; then
        return 0
    fi
    _fail "$message" "Value:    (empty)"
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain substring}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    fi
    _fail "$message" "String:   '$haystack'" "Missing:  '$needle'"
    return 0
}

# assert_not_contains <haystack> <needle> [message]
# The negative of assert_contains. Pure-bash glob, no eval — safe for
# attacker-influenceable strings (golem-gate-watch.sh and lint-action-pins.sh
# previously open-coded this with `case`-globs for exactly that reason).
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain substring}"
    if [[ "$haystack" != *"$needle"* ]]; then
        return 0
    fi
    _fail "$message" "String:   '$haystack'" "Unexpected: '$needle'"
    return 0
}

# assert_valid_json <value> [message]
# Asserts <value> is well-formed JSON. Takes the value as a real argument (no
# eval, no shell re-quoting) so it is safe for attacker-influenceable strings —
# unlike building `printf '%s' '$value' | jq -e .` for assert_true, where an
# embedded single quote would close the surrounding '...' early inside the
# eval'd command and let following metacharacters run. Skips (passes) when jq is
# absent; call sites already gate their suites on jq.
#
# `jq empty` is a syntax-only parse check (reads input, emits nothing, exits
# non-zero only on malformed JSON) — unlike `jq -e .`, whose exit status keys off
# the *truthiness* of the output, so the valid scalars `false`/`null` would be
# misreported as invalid.
assert_valid_json() {
    local value="$1"
    local message="${2:-Value should be valid JSON}"
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    if printf '%s' "$value" | jq empty >/dev/null 2>&1; then
        return 0
    fi
    _fail "$message" "Value:    '$(printf '%s' "$value" | command head -3)'"
    return 0
}

assert_exit() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Exit code should match}"
    if [ "$expected" = "$actual" ]; then
        return 0
    fi
    _fail "$message" "Expected exit: $expected" "Actual exit:   $actual"
    return 0
}

assert_output_empty() {
    local output="$1"
    local message="${2:-Output should be empty}"
    if [ -z "$output" ]; then
        return 0
    fi
    _fail "$message" "Output:   '$(printf '%s' "$output" | command head -3)'"
    return 0
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist}"
    if [ -f "$file" ]; then
        return 0
    fi
    _fail "$message" "File:     '$file'"
    return 0
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should contain pattern}"
    if [ ! -f "$file" ]; then
        _fail "$message" "File:     '$file'" "Error:    File does not exist"
        return 0
    fi
    if command grep -q -- "$pattern" "$file" 2>/dev/null; then
        return 0
    fi
    _fail "$message" "File:     '$file'" "Pattern:  '$pattern'"
    return 0
}

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local message="${3:-File should not contain pattern}"
    if [ ! -f "$file" ]; then
        # A non-existent file trivially does not contain the pattern.
        return 0
    fi
    if ! command grep -q -- "$pattern" "$file" 2>/dev/null; then
        return 0
    fi
    local match
    match=$(command grep -n -- "$pattern" "$file" 2>/dev/null | command head -1)
    _fail "$message" "File:     '$file'" "Pattern:  '$pattern'" "Match:    $match"
    return 0
}

# --- Contract-block extraction ----------------------------------------------
#
# LLM-followed prose (checker.md, the ship-issue protocols) carries guarantees
# that have no runtime to unit-test, so several gates pin them as PROSE
# CONTRACTS: extract the region that states a guarantee, assert the operative
# tokens are in it. The question is how a gate ADDRESSES that region.
#
# The original approach anchored on a pair of HEADING strings
# (`extract_between FILE '#### Step 3a:' '### Step 4:'`). That couples every
# assertion to where the prose sits and what its headings are called, which
# fails in three ways an in-place edit never reveals:
#
#   1. Moving the block to a companion file breaks every assertion pinning it,
#      even though the guarantee is unchanged — so a size-driven extraction
#      (#503) has to rewrite the gate in order to move prose.
#   2. Renaming a heading silently RE-ANCHORS rather than failing: a region can
#      run to the wrong END sentinel and quietly swallow unrelated prose. The
#      old helper needed a hand-maintained MAX_LINES bound per region purely to
#      notice that.
#   3. One block's heading was another region's END sentinel, so moving it
#      expanded a neighbouring region as a side effect.
#
# extract_contract addresses a block by a STABLE ID embedded in the prose:
#
#     <!-- contract: agnix-trust-config-pinning -->
#
# The region runs from that marker to the next `<!-- contract:` marker or EOF.
# The block may then be reworded, re-headed, or moved to another file without
# touching a single assertion — only deleting the marker breaks the gate, which
# is exactly the change that SHOULD break it.
#
# Fails LOUD, never vacuous: an ID that resolves to no marker, or to more than
# one, is a hard error rather than an empty region every assert_contains would
# then pass against. That vacuous-pass mode is the specific way a prose gate
# rots into sitting inert while reporting green.

# CONTRACT_SEARCH_ROOT — where extract_contract searches when given no file.
# Overridable so a gate can narrow the search; a gate that sets it can pin a
# block wherever it lives.
CONTRACT_SEARCH_ROOT="${CONTRACT_SEARCH_ROOT:-}"

# extract_contract <id> [file]
#
# Print the contract block for <id>. With <file>, search only that file; without
# it, search CONTRACT_SEARCH_ROOT (so a block that MOVES between files needs no
# gate edit). Exits non-zero with a diagnostic when the ID is missing or
# duplicated — callers run under `set -e`, so that aborts the suite rather than
# yielding an empty string.
extract_contract() {
    local id="$1" file="${2:-}"
    local marker="<!-- contract: ${id} -->"

    if [ -z "$id" ]; then
        command printf 'extract_contract: FATAL — called with an empty contract id\n' >&2
        return 2
    fi

    local files
    if [ -n "$file" ]; then
        files="$file"
    else
        if [ -z "$CONTRACT_SEARCH_ROOT" ]; then
            command printf 'extract_contract: FATAL — no file given and CONTRACT_SEARCH_ROOT is unset\n' >&2
            return 2
        fi
        # Line-initial only (see the extraction awk below): a prose mention of
        # the marker syntax must not make an id look present — or, worse,
        # duplicated across files, which would abort the suite.
        #
        # FIXED-STRING, not a regex. The marker is always a literal, and ids are
        # author-supplied, so building a pattern out of one means escaping it —
        # and a backslash-escaped `+ ? | ( ) { }` means OPPOSITE things in BRE
        # and ERE (GNU-only operators in BRE, literals on BSD/macOS). That is
        # the silent GNU-vs-BSD divergence CLAUDE.md singles out: the pattern
        # quietly stops matching, zero files come back, and the id then reports
        # as "not found". `grep -F` sidesteps the whole class — there is no
        # pattern to escape — and `-l` + the awk index()==1 check below enforce
        # the line-initial requirement that the `^` anchor used to.
        files="$(command grep -rlF "$marker" "$CONTRACT_SEARCH_ROOT" \
            --include='*.md' 2>/dev/null |
            while IFS= read -r _f; do
                # Keep only files where the marker STARTS a line.
                command awk -v m="$marker" 'index($0, m) == 1 { found = 1; exit }
                    END { exit !found }' "$_f" && command printf '%s\n' "$_f"
            done || true)"
    fi

    if [ -z "$files" ]; then
        command printf 'extract_contract: FATAL — contract id "%s" not found\n' "$id" >&2
        command printf '  Looked for the literal marker: %s\n' "$marker" >&2
        command printf '  A contract block was deleted or its id was renamed. The gate\n' >&2
        command printf '  pins a guarantee by id precisely so the prose can move freely —\n' >&2
        command printf '  restore the marker rather than re-anchoring the assertions.\n' >&2
        return 1
    fi

    local count
    count="$(command printf '%s\n' "$files" | command grep -c . || true)"
    if [ "$count" -ne 1 ]; then
        command printf 'extract_contract: FATAL — contract id "%s" found in %s files:\n' \
            "$id" "$count" >&2
        command printf '%s\n' "$files" | command sed 's/^/    /' >&2
        command printf '  Contract ids must be unique: two blocks claiming one id means an\n' >&2
        command printf '  assertion silently pins whichever file sorted first.\n' >&2
        return 1
    fi

    # Duplicate markers WITHIN one file are caught too — a second occurrence of
    # this same id would have ended the first region, so count before extracting.
    local occurrences
    occurrences="$(command grep -cF "$marker" "$files" || true)"
    if [ "$occurrences" -ne 1 ]; then
        command printf 'extract_contract: FATAL — contract id "%s" appears %s times in %s\n' \
            "$id" "$occurrences" "$files" >&2
        return 1
    fi

    # Emit from the line AFTER the marker up to (not including) the next
    # contract marker, or EOF.
    #
    # A delimiter must START the line. Prose that *mentions* the marker syntax
    # mid-sentence (the companion files explain these markers to their readers)
    # would otherwise terminate a region early — silently truncating it, so
    # assertions on the tail half fail with no hint why. Anchoring at column 0
    # keeps documentation about the mechanism from breaking the mechanism.
    command awk -v m="$marker" '
        index($0, m) == 1 { grab = 1; next }
        grab && index($0, "<!-- contract:") == 1 { exit }
        grab { print }
    ' "$files"
}

# assert_contract_carries <id> <region> <token> [label]
#
# The shared "this contract states this guarantee" assertion: the region is
# non-empty AND carries the operative token AND the token is genuinely present
# (stripping it changes the region). The tamper half is what stops an assertion
# passing against prose that never contained the token.
#
# Prefer OPERATIVE tokens — the literals a reader must obey (`AGNIX_CONFIG`,
# `--fix-unsafe`, a log-line format) — over rationale sentences. Rationale
# should be free to be reworded; an enforced instruction should not.
assert_contract_carries() {
    local id="$1" region="$2" token="$3"
    # Separate `local`: $id is not yet in effect within the declaration above,
    # so a default referencing it there would silently expand to empty (SC2318).
    local label="${4:-contract $id}"

    assert_not_empty "$region" "$label: contract '$id' region is non-empty"
    assert_contains "$region" "$token" "$label: carries '$token'"

    # Plain bash comparison (NOT assert_true, which eval's its argument — the
    # region holds shell metacharacters eval would execute).
    local tampered changed="no"
    tampered="$(command printf '%s\n' "$region" | command grep -vF "$token" || true)"
    [ "$region" != "$tampered" ] && changed="yes"
    assert_not_contains "$tampered" "$token" \
        "$label: stripping the line removes '$token' (assertion targets real prose)"
    assert_equals "yes" "$changed" \
        "$label: '$token' is genuinely present (tamper changed the region)"
}

# --- Reporting --------------------------------------------------------------

# generate_report prints a summary and exits non-zero if any test failed.
generate_report() {
    printf '\n%s\n' "${_C_BOLD}Summary${_C_RESET}"
    printf '  Total:   %d\n' "$TESTS_RUN"
    printf '  Passed:  %s%d%s\n' "${_C_GREEN}" "$TESTS_PASSED" "${_C_RESET}"
    printf '  Failed:  %s%d%s\n' "${_C_RED}" "$TESTS_FAILED" "${_C_RESET}"
    printf '  Skipped: %s%d%s\n' "${_C_YELLOW}" "$TESTS_SKIPPED" "${_C_RESET}"

    [ "$TESTS_FAILED" -eq 0 ]
}
