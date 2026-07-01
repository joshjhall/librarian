#!/usr/bin/env bash
# Test-file classification behavioral gate (issues #132, #134, #135).
#
# Both pre-scan scanners decide "is this path a test file?" via the shared
# is_test_file() helper (kept byte-identical by validate-shared-scanner-sync.sh):
#
#   plugins/review-audit/skills/check-code-health/patterns.sh
#   plugins/workflow/skills/ship-issue/pre-review-gates.sh
#
# Before #132 the two used DIFFERENT globs — a broad `*test*` (which wrongly
# skipped contest.py / latest.js) in one, and a narrow suffix-only set (which
# wrongly SCANNED tests/helper.py) in the other. This gate runs BOTH scanners
# over the same fixtures and asserts they now (a) AGREE and (b) classify the
# tricky cases correctly. It is the behavioral half of the drift guard: that
# gate proves the *source* is identical, this one proves the *behavior* is right.
#
# It also gives patterns.sh its first positive-fixture coverage (#135): prior
# tests only pinned its empty-list / missing-arg contract, never that its
# debug-statement detector actually fires.
#
# Both scanners emit TSV: file\tline\tcategory\tevidence\tcertainty. We assert on
# the debug-statement category (both scanners implement it identically).
#
# The scanners resolve _PROJECT_ROOT via `git rev-parse` (pre-review-gates.sh),
# so each invocation runs with git's hook-exported environment scrubbed — same
# hermetic discipline as validate-pre-review-gates.sh / validate-golem-scripts.sh.
#
# Pure bash + coreutils. Full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS="$REPO_ROOT/plugins/review-audit/skills/check-code-health/patterns.sh"
GATES="$REPO_ROOT/plugins/workflow/skills/ship-issue/pre-review-gates.sh"

REAL_BASH="$(command -v bash)"
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "scanner test-file classification (#132/#134/#135)"

WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# scan SCRIPT LIST — run a scanner with the git env scrubbed, echo only the
# debug-statement rows (3rd tab-column == debug-statement).
scan() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$1" "$2" 2>/dev/null |
        /usr/bin/awk -F '\t' '$3 == "debug-statement"'
}

# has_row ROWS SUBSTR — 0 if any row contains SUBSTR.
has_row() { /usr/bin/printf '%s\n' "$1" | /usr/bin/grep -qF "$2"; }

# fresh_dir — a unique per-case scratch dir under WORKDIR, so each test is
# self-contained rather than sharing (and overwriting) one fixture tree.
fresh_dir() { /usr/bin/mktemp -d "$WORKDIR/case.XXXXXX"; }

# --- Shared fixture tree --------------------------------------------------
# setup_fixtures DIR — write a debug statement into a spread of files that
# exercise EVERY is_test_file() arm plus the two must-flag source files.
#   SOURCE (must be flagged):
#     src/mod.js       — plain source
#     contest.js       — historical false-skip of the broad *test* glob
#   TEST (must be skipped) — one per is_test_file arm:
#     tests/helper.js  — tests/  dir segment
#     spec/widget.rb   — spec/   dir segment
#     x/__tests__/a.ts — __tests__/ embedded segment
#     test_util.py     — test_ prefix
#     widget_test.go   — _test.  suffix
#     api.spec.js      — .spec.  dot suffix
#     mod.test.ts      — .test.  dot suffix
# Every file carries a language-appropriate debug statement so that, absent the
# skip, the scanner WOULD emit a debug-statement row — the skip is what silences
# it, which is exactly what we assert.
setup_fixtures() {
    local d="$1"
    /usr/bin/mkdir -p "$d/src" "$d/tests" "$d/spec" "$d/x/__tests__"
    /usr/bin/printf '%s\n' "console.log('real source');" >"$d/src/mod.js"
    /usr/bin/printf '%s\n' "console.log('contest is NOT a test');" >"$d/contest.js"
    /usr/bin/printf '%s\n' "console.log('tests/ dir, skip');" >"$d/tests/helper.js"
    /usr/bin/printf '%s\n' "binding.pry" >"$d/spec/widget.rb"
    /usr/bin/printf '%s\n' "console.log('__tests__ dir, skip');" >"$d/x/__tests__/a.ts"
    /usr/bin/printf '%s\n' "print('test_ prefix, skip')" >"$d/test_util.py"
    /usr/bin/printf '%s\n' "fmt.Println(\"_test suffix\")" >"$d/widget_test.go"
    /usr/bin/printf '%s\n' "console.log('.spec suffix, skip');" >"$d/api.spec.js"
    /usr/bin/printf '%s\n' "console.log('.test suffix, skip');" >"$d/mod.test.ts"
    /usr/bin/printf '%s\n' \
        "$d/src/mod.js" "$d/contest.js" "$d/tests/helper.js" "$d/spec/widget.rb" \
        "$d/x/__tests__/a.ts" "$d/test_util.py" "$d/widget_test.go" \
        "$d/api.spec.js" "$d/mod.test.ts" >"$d/list.txt"
}

# Source files that MUST be flagged, and test files that MUST be skipped (one
# per is_test_file arm). Kept as newline lists so the assertion loops are simple.
SOURCE_FILES="src/mod.js
contest.js"
TEST_FILES="tests/helper.js
spec/widget.rb
x/__tests__/a.ts
test_util.py
widget_test.go
api.spec.js
mod.test.ts"

# assert_scanner_classifies SCRIPT LABEL DIR — real source flagged, every test
# file skipped. Direct has_row conditionals (NOT assert_true, which eval's its
# argument — $rows is scanner output over file content; see
# validate-shared-scanner-sync.sh for the same caution).
assert_scanner_classifies() {
    local script="$1" label="$2" dir="$3" rows f
    rows="$(scan "$script" "$dir/list.txt")"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! has_row "$rows" "$f"; then
            _fail "$label: source $f must be flagged, but no debug-statement row was emitted"
        fi
    done <<<"$SOURCE_FILES"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if has_row "$rows" "$f"; then
            _fail "$label: test file $f must be skipped by is_test_file, but it was flagged"
        fi
    done <<<"$TEST_FILES"
}

test_patterns_classifies() {
    local d
    d="$(fresh_dir)"
    setup_fixtures "$d"
    assert_scanner_classifies "$PATTERNS" "patterns.sh" "$d"
}

test_gates_classifies() {
    local d
    d="$(fresh_dir)"
    setup_fixtures "$d"
    assert_scanner_classifies "$GATES" "pre-review-gates.sh" "$d"
}

# The two scanners must produce the SAME set of flagged fixture files — the core
# #132 invariant (no divergent classification between the audit and ship gates).
test_scanners_agree() {
    local d p g pflag gflag f
    d="$(fresh_dir)"
    setup_fixtures "$d"
    p="$(scan "$PATTERNS" "$d/list.txt")"
    g="$(scan "$GATES" "$d/list.txt")"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        pflag=no
        gflag=no
        has_row "$p" "$f" && pflag=yes
        has_row "$g" "$f" && gflag=yes
        assert_equals "$pflag" "$gflag" "both scanners agree on ${f} (patterns=$pflag gates=$gflag)"
    done <<<"$SOURCE_FILES
$TEST_FILES"
}

run_test test_patterns_classifies "patterns.sh flags source, skips test files by path"
run_test test_gates_classifies "pre-review-gates.sh flags source, skips test files by path"
run_test test_scanners_agree "both scanners classify every fixture identically"

generate_report
