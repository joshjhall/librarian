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
# debug-statement detector actually fires. The two patterns.sh-only categories
# — tech-debt-marker and empty-handler — get their positive-fixture coverage
# here too (#139): they are NOT implemented by pre-review-gates.sh, so they have
# no cross-scanner-agreement dimension and are asserted against patterns.sh alone.
#
# Both scanners emit TSV: file\tline\tcategory\tevidence\tcertainty. The shared
# classification/agreement tests assert on the debug-statement category (both
# scanners implement it identically); the two patterns.sh-only tests below filter
# to their own category via scan_cat().
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

test_suite "scanner test-file classification (#132/#134/#135/#139)"

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# scan SCRIPT LIST — run a scanner with the git env scrubbed, echo only the
# debug-statement rows (3rd tab-column == debug-statement).
scan() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$1" "$2" 2>/dev/null |
        command awk -F '\t' '$3 == "debug-statement"'
}

# scan_cat SCRIPT LIST CATEGORY — like scan(), but filter to an arbitrary finding
# category (3rd tab-column). scan() is the debug-statement special case; the
# patterns.sh-only tech-debt-marker / empty-handler tests use this.
scan_cat() {
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" "$REAL_BASH" "$1" "$2" 2>/dev/null |
        command awk -F '\t' -v c="$3" '$3 == c'
}

# has_row ROWS SUBSTR — 0 if any row contains SUBSTR.
has_row() { command printf '%s\n' "$1" | command grep -qF "$2"; }

# fresh_dir — a unique per-case scratch dir under WORKDIR, so each test is
# self-contained rather than sharing (and overwriting) one fixture tree.
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

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
    command mkdir -p "$d/src" "$d/tests" "$d/spec" "$d/x/__tests__"
    command printf '%s\n' "console.log('real source');" >"$d/src/mod.js"
    command printf '%s\n' "console.log('contest is NOT a test');" >"$d/contest.js"
    command printf '%s\n' "console.log('tests/ dir, skip');" >"$d/tests/helper.js"
    command printf '%s\n' "binding.pry" >"$d/spec/widget.rb"
    command printf '%s\n' "console.log('__tests__ dir, skip');" >"$d/x/__tests__/a.ts"
    command printf '%s\n' "print('test_ prefix, skip')" >"$d/test_util.py"
    command printf '%s\n' "fmt.Println(\"_test suffix\")" >"$d/widget_test.go"
    command printf '%s\n' "console.log('.spec suffix, skip');" >"$d/api.spec.js"
    command printf '%s\n' "console.log('.test suffix, skip');" >"$d/mod.test.ts"
    command printf '%s\n' \
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

# --- patterns.sh-only categories (#139) -----------------------------------
# tech-debt-marker and empty-handler are implemented only in patterns.sh (not
# pre-review-gates.sh), so these are single-scanner positive-fixture tests with
# a negative control each — proving the detector fires on a real marker AND stays
# quiet on a clean file, so a broken regex (either direction) is caught.

# patterns.sh emits a tech-debt-marker row for each of the five keywords its
# regex matches (TODO|FIXME|HACK|XXX|WORKAROUND), and none for a clean file.
# One fixture per keyword so a regression that drops any single keyword from the
# alternation is caught — a one-keyword test would miss exactly that.
TECH_DEBT_KEYWORDS="TODO
FIXME
HACK
XXX
WORKAROUND"

test_patterns_tech_debt_fires() {
    local d rows kw
    d="$(fresh_dir)"
    # One .py file per keyword, plus a marker-free control.
    : >"$d/list.txt"
    while IFS= read -r kw; do
        [ -n "$kw" ] || continue
        command printf '%s\n' "# $kw: handle this" >"$d/debt_$kw.py"
        command printf '%s\n' "$d/debt_$kw.py" >>"$d/list.txt"
    done <<<"$TECH_DEBT_KEYWORDS"
    command printf '%s\n' "x = 1  # a plain comment, no marker" >"$d/clean.py"
    command printf '%s\n' "$d/clean.py" >>"$d/list.txt"

    rows="$(scan_cat "$PATTERNS" "$d/list.txt" tech-debt-marker)"

    while IFS= read -r kw; do
        [ -n "$kw" ] || continue
        if ! has_row "$rows" "$d/debt_$kw.py"; then
            _fail "patterns.sh: $kw marker must emit a tech-debt-marker row, but none was found"
        fi
    done <<<"$TECH_DEBT_KEYWORDS"
    if has_row "$rows" "$d/clean.py"; then
        _fail "patterns.sh: clean.py has no marker but a tech-debt-marker row was emitted for it"
    fi
}

# patterns.sh emits an empty-handler row for an except/pass block, and none for
# an except block with a real body.
test_patterns_empty_handler_fires() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "try:" "    do()" "except Exception:" "    pass" >"$d/empty.py"
    command printf '%s\n' "try:" "    do()" "except Exception:" "    handle()" >"$d/handled.py"
    command printf '%s\n' "$d/empty.py" "$d/handled.py" >"$d/list.txt"
    rows="$(scan_cat "$PATTERNS" "$d/list.txt" empty-handler)"

    if ! has_row "$rows" "$d/empty.py"; then
        _fail "patterns.sh: except/pass in empty.py must emit an empty-handler row, but none was found"
    fi
    if has_row "$rows" "$d/handled.py"; then
        _fail "patterns.sh: handled.py has a non-empty except body but an empty-handler row was emitted for it"
    fi
}

# The Python except/pass path above is one of five empty-handler detectors in
# patterns.sh. This covers the other four language branches — JS/TS catch{},
# Java/Kotlin catch{}, Ruby rescue/end, Go `if err != nil {}` — each with a
# positive fixture (empty body, must fire) and a negative control (real body,
# must not). Guards against a regression in any single language branch, which
# the Python-only test would miss (issue #141, deferred from PR #140).
test_patterns_empty_handler_multilang_fires() {
    local d rows
    d="$(fresh_dir)"

    # JS/TS — inline empty catch vs a catch with a real body.
    command printf '%s\n' "try { do(); } catch (e) {}" >"$d/empty.js"
    command printf '%s\n' "try { do(); } catch (e) { handle(e); }" >"$d/handled.js"
    # Java/Kotlin — same catch(){} shape.
    command printf '%s\n' "try { doThing(); } catch (Exception e) {}" >"$d/empty.java"
    command printf '%s\n' "try { doThing(); } catch (Exception e) { log(e); }" >"$d/handled.java"
    # Ruby — rescue whose next non-blank line closes the block, vs one with a body.
    command printf '%s\n' "begin" "  do_it" "rescue" "end" >"$d/empty.rb"
    command printf '%s\n' "begin" "  do_it" "rescue" "  handle" "end" >"$d/handled.rb"
    # Go — swallowed error (empty braces) vs a handled one.
    command printf '%s\n' "if err != nil {}" >"$d/empty.go"
    command printf '%s\n' "if err != nil { return err }" >"$d/handled.go"

    command printf '%s\n' \
        "$d/empty.js" "$d/handled.js" \
        "$d/empty.java" "$d/handled.java" \
        "$d/empty.rb" "$d/handled.rb" \
        "$d/empty.go" "$d/handled.go" >"$d/list.txt"

    rows="$(scan_cat "$PATTERNS" "$d/list.txt" empty-handler)"

    local lang
    for lang in js java rb go; do
        if ! has_row "$rows" "$d/empty.$lang"; then
            _fail "patterns.sh: empty handler in empty.$lang must emit an empty-handler row, but none was found"
        fi
        if has_row "$rows" "$d/handled.$lang"; then
            _fail "patterns.sh: handled.$lang has a non-empty handler body but an empty-handler row was emitted for it"
        fi
    done

    # Exactly four rows — one per empty fixture. Guards against a language
    # branch cross-firing on another language's file (all rows share the same
    # "empty-handler" category, so the per-language checks above can't catch it).
    local count
    count="$(command printf '%s\n' "$rows" | command grep -c . || true)"
    if [ "$count" -ne 4 ]; then
        _fail "patterns.sh: expected exactly 4 empty-handler rows (one per language), got $count"
    fi
}

run_test test_patterns_classifies "patterns.sh flags source, skips test files by path"
run_test test_gates_classifies "pre-review-gates.sh flags source, skips test files by path"
run_test test_scanners_agree "both scanners classify every fixture identically"
run_test test_patterns_tech_debt_fires "patterns.sh fires tech-debt-marker on all 5 keywords, not on clean file"
run_test test_patterns_empty_handler_fires "patterns.sh fires empty-handler on except/pass, not on handled block"
run_test test_patterns_empty_handler_multilang_fires "patterns.sh fires empty-handler on JS/Java/Ruby/Go empty handlers, not on handled blocks"

generate_report
