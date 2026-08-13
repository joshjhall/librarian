#!/usr/bin/env bash
# dev-core loop-* + drift-detect detector behavioral gate (issue #384, slice B of #348).
#
# The six dev-core pre-scan ports —
#
#   loop-make-it-work        (stub-detected / empty-body / no-assertions)
#   loop-make-it-right       (long-function / deep-nesting / single-char-name)
#   loop-make-it-secure      (hardcoded-secret / string-interpolation-query /
#                             dangerous-function / denylist-validation)
#   loop-make-it-tested      (missing-test-file / untested-public-api)
#   loop-make-it-documented  (undocumented-public-function / -public-class / -export)
#   drift-detect             (planned-not-touched / unplanned-modification)
#
# — were the lowest-coverage Python ports left after the source slice #383
# (66–80% line-rate) because, like the check-docs-* / check-security family before
# them, NONE had a dedicated behavioral gate: only tests/validate-python-ports.sh
# covered them, and it asserts bash==python PARITY over one shared fixture tree,
# which — as its own header notes — "cannot catch a regression where both impls
# break the same way." Whole per-language / per-category arms (the JS/Go/shell
# documented splits, the brace long-function counter, the per-language
# no-assertions emits, the yaml-Loader deserialization boundary, the sibling
# test-file probes, the drift test-for-planned LOW arm) never executed and had
# zero output-asserting coverage.
#
# This gate is the behavioral half of the #204 two-surface convention for the
# loop family: it drives PURPOSE-BUILT fixtures through each scanner and asserts
# the SPECIFIC finding category each fixture must emit — AND that a clean
# counter-fixture stays silent — with emphasis on BOUNDARIES and NEGATIVE paths
# (the documented/undocumented split per language, the yaml.load Loader= exclusion,
# the single-char loop-counter skip, the sibling-test-present suppression, the
# drift side-effect/test LOW vs unlisted MEDIUM split, the SKIP_GLOBS whole-file
# skip). The sibling tests/coverage-python.sh corpus is extended in lockstep so the
# same branches execute under measurement; coverage rises because behavior is
# asserted, never the reverse.
#
# Each category is asserted against BOTH the Python primary (patterns.py) and the
# bash fallback (PATTERNS_FORCE_BASH=1 patterns.sh) — free parity reinforcement on
# top of validate-python-ports.sh's whole-corpus diff.
#
# Fault-injection verified (the #221 precedent): each boundary below was proven to
# catch a regression by transiently mutating the port and confirming this gate goes
# red, then reverting. The mutations checked, one per port:
#   loop-make-it-work       — the no-assertions `if not any(...)` guard forced true
#                             (so a test file WITH an assert would wrongly fire) →
#                             the has-assert silent assertion goes red.
#   loop-make-it-right      — the single-char `varname in SKIP_VARNAMES` skip
#                             emptied (so a loop-counter `x` would wrongly fire) →
#                             the skip silent assertion goes red.
#   loop-make-it-secure     — the LOADER_EXCLUDE_RE guard dropped (so a
#                             yaml.load(..., Loader=Safe) would wrongly fire) → the
#                             Loader= silent assertion goes red.
#   loop-make-it-tested     — the missing-test-file `if not has_test` inverted (so a
#                             file WITH a sibling test would wrongly fire) → the
#                             sibling-present silent assertion goes red.
#   loop-make-it-documented — the py-docstring `if not PY_DOCSTRING_RE` guard forced
#                             true (so a documented def would wrongly fire) → the
#                             docstring silent assertion goes red.
#   drift-detect            — the side-effect/test LOW branch forced to MEDIUM (so a
#                             package-lock.json would report MEDIUM) → the LOW
#                             assertion goes red.
# All six went red under mutation and green on revert.
#
# loop-make-it-tested and loop-make-it-documented (shell arm) probe the working
# tree (sibling test files, function-preceding comments), so their fixtures build a
# small on-disk tree under a fresh_dir. The other four read only file CONTENT (no
# git-rooting), so their CWD is irrelevant and every fixture runs from $WORKDIR.
#
# SKIPS (does not fail) when a python3>=3.11 is unavailable — the same posture as
# validate-python-ports.sh; the bash path is still asserted where present.
#
# Pure bash-3.2 + coreutils; full /usr/bin/* paths per project convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/plugins/dev-core/skills"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "dev-core loop-* + drift-detect detector fixtures (#384)"

HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

SK_WORK="$SKILLS_DIR/loop-make-it-work"
SK_RIGHT="$SKILLS_DIR/loop-make-it-right"
SK_SEC="$SKILLS_DIR/loop-make-it-secure"
SK_TEST="$SKILLS_DIR/loop-make-it-tested"
SK_DOC="$SKILLS_DIR/loop-make-it-documented"
SK_DRIFT="$SKILLS_DIR/drift-detect"

# --- Scanner drivers ---------------------------------------------------------
# emit_rows IMPL SKILLDIR CAT ENV.. -- ARGS.. — the rows one impl emits for a
# single category. IMPL is "py" or "sh". Everything after `--` is the argv passed
# to the scanner (a single file-list for the loop ports; actual+planned lists for
# drift). Env overrides go before `--`.
emit_rows() {
    local impl="$1" skill="$2" cat="$3"
    shift 3
    local env_kv=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        env_kv+=("$1")
        shift
    done
    shift # drop the `--`
    if [ "$impl" = py ]; then
        /usr/bin/env "${env_kv[@]}" python3 "$skill/patterns.py" "$@" 2>/dev/null
    else
        /usr/bin/env PATTERNS_FORCE_BASH=1 "${env_kv[@]}" \
            "$REAL_BASH" "$skill/patterns.sh" "$@" 2>/dev/null
    fi | command awk -F '\t' -v c="$cat" '$3 == c'
}

# assert_fires SKILLDIR CAT NEEDLE MSG ENV.. -- ARGS.. — the category fires (rows
# contain NEEDLE) in BOTH impls. Python side skipped (not failed) when absent.
assert_fires() {
    local skill="$1" cat="$2" needle="$3" msg="$4"
    shift 4
    assert_contains "$(emit_rows sh "$skill" "$cat" "$@")" \
        "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_contains "$(emit_rows py "$skill" "$cat" "$@")" \
            "$needle" "$msg (python)"
    fi
}

# assert_absent SKILLDIR CAT NEEDLE MSG ENV.. -- ARGS.. — the category's rows do
# NOT contain NEEDLE, in both impls.
#
# Distinct from assert_silent, which requires the category to be EMPTY. This one
# is for a fixture where the category legitimately fires for one symbol while a
# second symbol must be absent — asserting emptiness there would be wrong, and
# asserting only the positive would let an over-broad detector pass (#606).
assert_absent() {
    local skill="$1" cat="$2" needle="$3" msg="$4"
    shift 4
    assert_not_contains "$(emit_rows sh "$skill" "$cat" "$@")" \
        "$needle" "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_not_contains "$(emit_rows py "$skill" "$cat" "$@")" \
            "$needle" "$msg (python)"
    fi
}

# assert_silent SKILLDIR CAT MSG ENV.. -- ARGS.. — the category emits NOTHING in
# both impls.
assert_silent() {
    local skill="$1" cat="$2" msg="$3"
    shift 3
    assert_output_empty "$(emit_rows sh "$skill" "$cat" "$@")" \
        "$msg (bash)"
    if [ "$HAVE_PY" -eq 1 ]; then
        assert_output_empty "$(emit_rows py "$skill" "$cat" "$@")" \
            "$msg (python)"
    fi
}

# fresh_dir — unique scratch dir per fixture so path resolution is clean.
fresh_dir() { command mktemp -d "$WORKDIR/case.XXXXXX"; }

# make_list OUTFILE PATH... — write a newline file list, echo its path.
make_list() {
    local out="$1"
    shift
    : >"$out"
    local p
    for p in "$@"; do
        command printf '%s\n' "$p" >>"$out"
    done
    command printf '%s' "$out"
}

# Fake secrets assembled from fragments so THIS gate file holds no contiguous
# secret for gitleaks to flag; the fixture on disk carries the full token (obvious
# fakes — sequential/repeated filler).
AKIA_TOK="AKIA""0123456789ABCDEF"
SECRET_VAL="abcdefgh""ijklmnop1234"

# ============================================================================
# loop-make-it-work — stub-detected / empty-body / no-assertions
# ============================================================================
test_work_stub_and_body() {
    local d list

    # stub-detected: a TODO/FIXME/NotImplementedError marker fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'def f():  # TODO: finish this' '    raise NotImplementedError' >"$d/s.py"
    list="$(make_list "$d/l" "$d/s.py")"
    assert_fires "$SK_WORK" stub-detected "Stub/placeholder" \
        "work: a TODO / NotImplementedError stub fires" -- "$list"

    # empty-body: Python def whose next non-blank line is only `pass`.
    d="$(fresh_dir)"
    command printf '%s\n' 'def empty():' '    pass' >"$d/e.py"
    list="$(make_list "$d/l" "$d/e.py")"
    assert_fires "$SK_WORK" empty-body "Empty function body" \
        "work: a Python pass-only body fires" -- "$list"

    # empty-body: JS arrow with empty braces.
    d="$(fresh_dir)"
    command printf '%s\n' 'const f = () => {}' >"$d/e.js"
    list="$(make_list "$d/l" "$d/e.js")"
    assert_fires "$SK_WORK" empty-body "Empty function body" \
        "work: a JS empty arrow body fires" -- "$list"

    # empty-body: Go empty func braces.
    d="$(fresh_dir)"
    command printf '%s\n' 'func Noop() {}' >"$d/e.go"
    list="$(make_list "$d/l" "$d/e.go")"
    assert_fires "$SK_WORK" empty-body "Empty function body" \
        "work: a Go empty func body fires" -- "$list"

    # BOUNDARY: a def as the LAST line (no following non-blank) does NOT fire an
    # empty-body — _first_nonblank_after returns '' at EOF (the '' return arm).
    d="$(fresh_dir)"
    command printf '%s\n' 'x = 1' 'def trailing():' >"$d/t.py"
    list="$(make_list "$d/l" "$d/t.py")"
    assert_silent "$SK_WORK" empty-body \
        "work: a def as the last line does not fire empty-body (EOF boundary)" -- "$list"
}

test_work_no_assertions() {
    local d list

    # no-assertions: a Python test file with NO assert fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'def test_a():' '    do_thing()' >"$d/test_x.py"
    list="$(make_list "$d/l" "$d/test_x.py")"
    assert_fires "$SK_WORK" no-assertions "no assertion statements" \
        "work: a Python test file with no assert fires" -- "$list"

    # ...but a Python test file WITH an assert stays silent (negative).
    d="$(fresh_dir)"
    command printf '%s\n' 'def test_a():' '    assert do_thing()' >"$d/test_y.py"
    list="$(make_list "$d/l" "$d/test_y.py")"
    assert_silent "$SK_WORK" no-assertions \
        "work: a Python test file with an assert stays silent" -- "$list"

    # no-assertions: a JS *.test.ts with no expect/assert fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'it("works", () => { run(); });' >"$d/x.test.ts"
    list="$(make_list "$d/l" "$d/x.test.ts")"
    assert_fires "$SK_WORK" no-assertions "no assertion statements" \
        "work: a JS .test.ts with no expect fires" -- "$list"

    # no-assertions: a Go *_test.go with no t.Error/assert fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'package p' 'func TestX(t *testing.T) { run() }' >"$d/x_test.go"
    list="$(make_list "$d/l" "$d/x_test.go")"
    assert_fires "$SK_WORK" no-assertions "no assertion statements" \
        "work: a Go _test.go with no t.Error fires" -- "$list"

    # ...and the FORMATTING variants stay silent (#684). `t.Errorf`/`Fatalf`/
    # `Logf` are Go's dominant assertion idioms, and the old trailing `\b`
    # rejected all three (`f` is a word character) — so an ordinary, correct Go
    # test was reported as having NO assertions at HIGH.
    #
    # This is the negative case the Go arm never had: the positive above fires
    # whether or not the boundary is right, so nothing caught the defect. Each
    # variant gets its own fixture rather than one file containing all three,
    # or a single surviving alternative would mask the other two.
    local variant
    for variant in Errorf Fatalf Logf; do
        d="$(fresh_dir)"
        command printf '%s\n' 'package p' \
            "func TestX(t *testing.T) { t.${variant}(\"boom: %v\", err) }" \
            >"$d/x_test.go"
        list="$(make_list "$d/l" "$d/x_test.go")"
        assert_silent "$SK_WORK" no-assertions \
            "work: a Go _test.go using t.${variant} stays silent (#684)" -- "$list"
    done

    # ...and the accepted suffix is exactly `f`, not "anything". The fix spells
    # out `(Error|Fatal|Log)f?` rather than dropping the trailing boundary,
    # because a bare drop would treat ANY identifier with one of these prefixes
    # as an assertion. Without this case, the looser pattern passes every test
    # above and the tightening is only a claim in a comment.
    d="$(fresh_dir)"
    command printf '%s\n' 'package p' \
        'func TestX(t *testing.T) { _ = t.ErrorHandlerConfig }' \
        >"$d/x_test.go"
    list="$(make_list "$d/l" "$d/x_test.go")"
    assert_fires "$SK_WORK" no-assertions "no assertion statements" \
        "work: t.ErrorHandlerConfig is NOT an assertion — suffix is f?, not .* (#684)" -- "$list"
}

# ============================================================================
# loop-make-it-right — long-function / deep-nesting / single-char-name
# ============================================================================
test_right_long_function() {
    local d list

    # Python long-function (max=1): a 2-line def fires; evidence colon-stripped.
    d="$(fresh_dir)"
    command printf '%s\n' 'def f():' '    a()' '    b()' >"$d/p.py"
    list="$(make_list "$d/l" "$d/p.py")"
    assert_fires "$SK_RIGHT" long-function "def f()" \
        "right: a Python long function fires (colon-stripped evidence)" \
        LOOP_MAX_FUNCTION_LINES=1 LOOP_MAX_NESTING_DEPTH=99 -- "$list"

    # Brace long-function (max=1): a multi-line JS function fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'function foo() {' '  x()' '}' >"$d/b.js"
    list="$(make_list "$d/l" "$d/b.js")"
    assert_fires "$SK_RIGHT" long-function "function foo()" \
        "right: a brace-language long function fires" \
        LOOP_MAX_FUNCTION_LINES=1 LOOP_MAX_NESTING_DEPTH=99 -- "$list"
}

test_right_deep_nesting() {
    local d list

    # deep-nesting (max=0): an indented Python line fires (4-space unit).
    d="$(fresh_dir)"
    command printf '%s\n' 'def f():' '    deep()' >"$d/n.py"
    list="$(make_list "$d/l" "$d/n.py")"
    assert_fires "$SK_RIGHT" deep-nesting "Nesting depth" \
        "right: an indented Python line fires deep-nesting" \
        LOOP_MAX_FUNCTION_LINES=999 LOOP_MAX_NESTING_DEPTH=0 -- "$list"

    # deep-nesting (max=0): a brace-language file uses a 2-space unit — assert the
    # separate BRACE_EXTS arm fires (a JS line indented 2 spaces → depth 1).
    d="$(fresh_dir)"
    command printf '%s\n' 'function f() {' '  deep()' '}' >"$d/n.js"
    list="$(make_list "$d/l" "$d/n.js")"
    assert_fires "$SK_RIGHT" deep-nesting "Nesting depth" \
        "right: an indented brace-language line fires deep-nesting (2-space unit)" \
        LOOP_MAX_FUNCTION_LINES=999 LOOP_MAX_NESTING_DEPTH=0 -- "$list"
}

test_right_single_char() {
    local d list

    # single-char-name: a non-conventional single letter assignment fires.
    d="$(fresh_dir)"
    command printf '%s\n' '    z = compute()' >"$d/s.py"
    list="$(make_list "$d/l" "$d/s.py")"
    assert_fires "$SK_RIGHT" single-char-name "Single-character variable 'z'" \
        "right: a single-char 'z' assignment fires" \
        LOOP_MAX_FUNCTION_LINES=999 LOOP_MAX_NESTING_DEPTH=999 -- "$list"

    # BOUNDARY: a conventional loop-counter 'x' is in SKIP_VARNAMES → silent.
    d="$(fresh_dir)"
    command printf '%s\n' '    x = compute()' >"$d/x.py"
    list="$(make_list "$d/l" "$d/x.py")"
    assert_silent "$SK_RIGHT" single-char-name \
        "right: a loop-counter 'x' stays silent (SKIP_VARNAMES boundary)" \
        LOOP_MAX_FUNCTION_LINES=999 LOOP_MAX_NESTING_DEPTH=999 -- "$list"

    # BOUNDARY: a `_ =` throwaway assignment is skipped by PY_SINGLE_SKIP_RE.
    d="$(fresh_dir)"
    command printf '%s\n' '    _ = compute()' >"$d/u.py"
    list="$(make_list "$d/l" "$d/u.py")"
    assert_silent "$SK_RIGHT" single-char-name \
        "right: a '_ =' throwaway stays silent (skip-regex boundary)" \
        LOOP_MAX_FUNCTION_LINES=999 LOOP_MAX_NESTING_DEPTH=999 -- "$list"
}

# ============================================================================
# loop-make-it-secure — secret / interpolation-query / dangerous-fn / denylist
# ============================================================================
test_secure_secret() {
    local d list

    # hardcoded-secret: a keyed literal fires.
    d="$(fresh_dir)"
    command printf 'api_key = "%s"\n' "$SECRET_VAL" >"$d/k.py"
    list="$(make_list "$d/l" "$d/k.py")"
    assert_fires "$SK_SEC" hardcoded-secret "Possible hardcoded secret" \
        "secure: a keyed secret literal fires" -- "$list"

    # hardcoded-secret: an AWS access-key pattern fires.
    d="$(fresh_dir)"
    command printf 'aws = "%s"\n' "$AKIA_TOK" >"$d/a.py"
    list="$(make_list "$d/l" "$d/a.py")"
    assert_fires "$SK_SEC" hardcoded-secret "AWS access key pattern" \
        "secure: an AWS AKIA key fires" -- "$list"

    # BOUNDARY: a *test* file carrying a real secret is skipped wholesale.
    d="$(fresh_dir)"
    command printf 'api_key = "%s"\n' "$SECRET_VAL" >"$d/test_secrets.py"
    list="$(make_list "$d/l" "$d/test_secrets.py")"
    assert_silent "$SK_SEC" hardcoded-secret \
        "secure: a secret inside a *test* file is skipped (SKIP_GLOBS boundary)" -- "$list"
}

test_secure_interpolation() {
    local d list

    # Python execute(f"...") interpolation.
    d="$(fresh_dir)"
    command printf '%s\n' 'cur.execute(f"SELECT * FROM t WHERE id={i}")' >"$d/q.py"
    list="$(make_list "$d/l" "$d/q.py")"
    assert_fires "$SK_SEC" string-interpolation-query "SQL with string interpolation" \
        "secure: a Python execute(f-string) fires" -- "$list"

    # JS query(`...SELECT...`) template literal.
    d="$(fresh_dir)"
    command printf '%s\n' 'db.query(`SELECT * FROM t WHERE x=${v}`);' >"$d/q.js"
    list="$(make_list "$d/l" "$d/q.js")"
    assert_fires "$SK_SEC" string-interpolation-query "SQL with string interpolation" \
        "secure: a JS query(template-literal) fires" -- "$list"

    # Go Query(fmt.Sprintf(...)).
    d="$(fresh_dir)"
    command printf '%s\n' 'db.Query(fmt.Sprintf("SELECT %s", x))' >"$d/q.go"
    list="$(make_list "$d/l" "$d/q.go")"
    assert_fires "$SK_SEC" string-interpolation-query "SQL with string interpolation" \
        "secure: a Go Query(fmt.Sprintf) fires" -- "$list"
}

test_secure_dangerous_and_denylist() {
    local d list

    # dangerous-function: subprocess.call(..., shell=True).
    d="$(fresh_dir)"
    command printf '%s\n' 'subprocess.call(cmd, shell=True)' >"$d/d.py"
    list="$(make_list "$d/l" "$d/d.py")"
    assert_fires "$SK_SEC" dangerous-function "Dangerous function usage" \
        "secure: subprocess.call(shell=True) fires" -- "$list"

    # dangerous-function: the SECOND DANGER_FN_RE alternative, child_process.exec(,
    # fires independently of the subprocess.call arm above.
    d="$(fresh_dir)"
    command printf '%s\n' 'child_process.exec(userCmd)' >"$d/cp.js"
    list="$(make_list "$d/l" "$d/cp.js")"
    assert_fires "$SK_SEC" dangerous-function "Dangerous function usage" \
        "secure: child_process.exec( fires (2nd DANGER_FN_RE alternative)" -- "$list"

    # dangerous-function: yaml.load WITHOUT a Loader= fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'data = yaml.load(payload)' >"$d/y.py"
    list="$(make_list "$d/l" "$d/y.py")"
    assert_fires "$SK_SEC" dangerous-function "Unsafe deserialization" \
        "secure: yaml.load without Loader= fires" -- "$list"

    # dangerous-function: the OTHER UNSAFE_DESERIALIZE_RE alternative, marshal.loads(,
    # is always unsafe (no Loader= escape hatch applies).
    d="$(fresh_dir)"
    command printf '%s\n' 'obj = marshal.loads(blob)' >"$d/m.py"
    list="$(make_list "$d/l" "$d/m.py")"
    assert_fires "$SK_SEC" dangerous-function "Unsafe deserialization" \
        "secure: marshal.loads( fires (marshal deserialization alternative)" -- "$list"

    # ...but yaml.load WITH an explicit Loader= stays silent (exclusion boundary).
    d="$(fresh_dir)"
    command printf '%s\n' 'data = yaml.load(payload, Loader=SafeLoader)' >"$d/ys.py"
    list="$(make_list "$d/l" "$d/ys.py")"
    assert_silent "$SK_SEC" dangerous-function \
        "secure: yaml.load with Loader= stays silent (Loader exclusion boundary)" -- "$list"

    # denylist-validation: a blacklist array literal.
    d="$(fresh_dir)"
    command printf '%s\n' 'blacklist = ["a", "b"]' >"$d/bl.py"
    list="$(make_list "$d/l" "$d/bl.py")"
    assert_fires "$SK_SEC" denylist-validation "Denylist pattern" \
        "secure: a blacklist array fires denylist-validation" -- "$list"
}

# ============================================================================
# loop-make-it-tested — missing-test-file / untested-public-api (filesystem)
# ============================================================================
test_tested_missing_and_untested() {
    local d list

    # missing-test-file + untested-public-api fire when NO sibling test exists.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' 'def public_fn():' '    return 0' >"$d/src/mod.py"
    list="$(make_list "$d/l" "$d/src/mod.py")"
    assert_fires "$SK_TEST" missing-test-file "No test file found" \
        "tested: a source file with no sibling test fires missing-test-file" -- "$list"
    assert_fires "$SK_TEST" untested-public-api "No tests reference public_fn" \
        "tested: a public fn with no test reference fires untested-public-api" -- "$list"

    # BOUNDARY: a sibling test_mod.py REFERENCING the fn suppresses BOTH.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' 'def public_fn():' '    return 0' >"$d/src/mod.py"
    command printf '%s\n' 'def test_it():' '    public_fn()' >"$d/src/test_mod.py"
    list="$(make_list "$d/l" "$d/src/mod.py")"
    assert_silent "$SK_TEST" missing-test-file \
        "tested: a present sibling test suppresses missing-test-file (boundary)" -- "$list"
    assert_silent "$SK_TEST" untested-public-api \
        "tested: a test referencing the fn suppresses untested-public-api" -- "$list"

    # SPLIT: a sibling test that does NOT reference the fn → missing-test-file
    # silent (sibling exists) but untested-public-api still fires.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' 'def public_fn():' '    return 0' >"$d/src/mod.py"
    command printf '%s\n' 'def test_other():' '    other()' >"$d/src/test_mod.py"
    list="$(make_list "$d/l" "$d/src/mod.py")"
    assert_silent "$SK_TEST" missing-test-file \
        "tested: an unrelated sibling test still suppresses missing-test-file" -- "$list"
    assert_fires "$SK_TEST" untested-public-api "No tests reference public_fn" \
        "tested: a sibling test not referencing the fn still fires untested-public-api" -- "$list"

    # Go: an exported func with a sibling _test.go that does NOT reference it fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'package p' 'func DoThing() {}' >"$d/svc.go"
    command printf '%s\n' 'package p' 'func TestOther(t *testing.T) {}' >"$d/svc_test.go"
    list="$(make_list "$d/l" "$d/svc.go")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference DoThing" \
        "tested: a Go exported func absent from _test.go fires untested-public-api" -- "$list"
}

# loop-make-it-tested — module public-symbol selection (#606).
#
# This scanner carried the same defect as ship-issue's pre-review-gates.sh: every
# non-underscore top-level `def` counted as public API, so an internal helper of a
# main()-guarded CLI script — driven end-to-end THROUGH the entry point, never
# imported, never named by a test — reported HIGH "no tests reference".
#
# assert_fires/assert_silent each assert BOTH the bash fallback and the python
# primary, so every case below is parity-checked for free.
test_tested_module_public_symbol_gate() {
    local d list

    # AC#1 + AC#2. A helper in a main()-guarded module is not public API; the
    # control in a SEPARATE, unguarded module must still fire. Separate files on
    # purpose: one module that both arms the gate and satisfies it would pass
    # whether or not the gate exists.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' \
        'def guarded_helper(a):' '    return a' \
        'def main(argv):' '    return guarded_helper(argv)' \
        'if __name__ == "__main__":' '    raise SystemExit(main(None))' >"$d/src/cli.py"
    command printf '%s\n' 'def library_export(a):' '    return a' >"$d/src/lib.py"
    list="$(make_list "$d/l" "$d/src/cli.py")"
    assert_silent "$SK_TEST" untested-public-api \
        "tested: a helper in a main()-guarded CLI module is not public API (#606)" -- "$list"
    list="$(make_list "$d/l2" "$d/src/lib.py")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference library_export" \
        "tested: a public untested def in a PLAIN module still fires (#606 control)" -- "$list"

    # The guard must be the MODULE's entry point — an indented one inside a
    # function is not, and must not silence the file.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' \
        'def outer(a):' '    if __name__ == "__main__":' '        pass' '    return a' \
        >"$d/src/nested.py"
    list="$(make_list "$d/l" "$d/src/nested.py")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference outer" \
        "tested: an INDENTED __main__ guard does not gate the module (#606)" -- "$list"

    # __all__ overrides the guard in BOTH directions. `phantom_helper` is quoted
    # in a constant BELOW a single-line __all__: it must not leak into the name
    # list (the sed-range overrun the awk extractor exists to avoid).
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' \
        '__all__ = ["declared_api"]' \
        'MSG = ("phantom_helper",)' \
        'def declared_api(a):' '    return a' \
        'def phantom_helper(b):' '    return b' \
        'if __name__ == "__main__":' '    pass' >"$d/src/dual.py"
    list="$(make_list "$d/l" "$d/src/dual.py")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference declared_api" \
        "tested: a name in __all__ stays public inside a guarded module (#606)" -- "$list"
    assert_absent "$SK_TEST" untested-public-api "No tests reference phantom_helper" \
        "tested: a quoted string after a single-line __all__ is not an exported name (#606)" -- "$list"

    # A MULTI-LINE __all__ collects every listed name across its continuation
    # lines, and still excludes what it omits. Covered here and not only in
    # validate-pre-review-gates.sh: this scanner's two impls are independently
    # maintained copies of the algorithm, and validate-python-ports.sh's
    # whole-corpus TSV parity does not target this shape — a regression in the
    # continuation loop would otherwise ship unseen.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' \
        '__all__ = [' '    "alpha",' '    "beta",' ']' \
        'def alpha(a):' '    return a' \
        'def beta(b):' '    return b' \
        'def gamma(c):' '    return c' >"$d/src/multi.py"
    list="$(make_list "$d/l" "$d/src/multi.py")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference alpha" \
        "tested: the first multi-line __all__ name is public (#606)" -- "$list"
    assert_fires "$SK_TEST" untested-public-api "No tests reference beta" \
        "tested: a LATER multi-line __all__ name is public too (#606)" -- "$list"
    assert_absent "$SK_TEST" untested-public-api "No tests reference gamma" \
        "tested: a def absent from a multi-line __all__ is not public API (#606)" -- "$list"

    # __all__ membership is WHOLE-WORD: a strict prefix of a listed name must not
    # inherit its public status via substring accident.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' \
        '__all__ = ["check_mcp_config"]' \
        'def check_mcp_config(a):' '    return a' \
        'def check_mcp(b):' '    return b' \
        'if __name__ == "__main__":' '    pass' >"$d/src/prefix.py"
    list="$(make_list "$d/l" "$d/src/prefix.py")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference check_mcp_config" \
        "tested: the listed __all__ name itself is public (#606)" -- "$list"
    assert_absent "$SK_TEST" untested-public-api "No tests reference check_mcp:" \
        "tested: a strict PREFIX of a listed name is not public (#606)" -- "$list"

    # An ANNOTATED declaration — `__all__: list[str] = [...]` — is valid,
    # ruff-clean Python. Missing it meant a guarded module's real API resolved to
    # "none" and its genuinely-untested exports were silently swallowed.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' \
        '__all__: list[str] = ["annotated_api"]' \
        'def annotated_api(a):' '    return a' \
        'def annotated_helper(b):' '    return b' \
        'if __name__ == "__main__":' '    pass' >"$d/src/annot.py"
    list="$(make_list "$d/l" "$d/src/annot.py")"
    assert_fires "$SK_TEST" untested-public-api "No tests reference annotated_api" \
        "tested: an ANNOTATED __all__ is recognized (#606)" -- "$list"
    assert_absent "$SK_TEST" untested-public-api "No tests reference annotated_helper" \
        "tested: an annotated __all__ still excludes what it omits (#606)" -- "$list"

    # The missing third colocated glob (#606): a src/ module whose test lives in
    # a SIBLING tests/ tree. pre-review-gates.sh's py arm has always probed
    # ../tests/test_*.py; this scanner did not, so that whole layout fired HIGH.
    d="$(fresh_dir)"
    command mkdir -p "$d/src" "$d/tests"
    command printf '%s\n' 'def sibling_tree_fn(a):' '    return a' >"$d/src/mod.py"
    command printf '%s\n' 'def test_it():' '    sibling_tree_fn(1)' >"$d/tests/test_mod.py"
    list="$(make_list "$d/l" "$d/src/mod.py")"
    assert_silent "$SK_TEST" untested-public-api \
        "tested: a test in a SIBLING tests/ tree suppresses the row (#606)" -- "$list"
}

# The TS/JS and Rust missing-test-file probe arms (separate from the py/go arms
# above) — each language resolves siblings differently, so assert each on its own.
test_tested_ts_and_rust() {
    local d list

    # TS: a *.test.<ext> sibling suppresses missing-test-file; its absence fires.
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' 'export const a = 1;' >"$d/src/comp.ts"
    list="$(make_list "$d/l" "$d/src/comp.ts")"
    assert_fires "$SK_TEST" missing-test-file "No test file found" \
        "tested: a .ts file with no sibling test fires missing-test-file" -- "$list"
    command printf '%s\n' 'test("c", () => {});' >"$d/src/comp.test.ts"
    assert_silent "$SK_TEST" missing-test-file \
        "tested: a <name>.test.ts sibling suppresses missing-test-file" -- "$list"

    # TS: a __tests__/<name>.test.<ext> sibling also suppresses it.
    d="$(fresh_dir)"
    command mkdir -p "$d/src/__tests__"
    command printf '%s\n' 'export const a = 1;' >"$d/src/widget.tsx"
    command printf '%s\n' 'test("w", () => {});' >"$d/src/__tests__/widget.test.tsx"
    list="$(make_list "$d/l" "$d/src/widget.tsx")"
    assert_silent "$SK_TEST" missing-test-file \
        "tested: a __tests__/<name>.test.tsx sibling suppresses missing-test-file" -- "$list"

    # Rust: an inline #[cfg(test)] block counts as a test (silent)...
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' 'fn thing() {}' '#[cfg(test)]' 'mod tests {}' >"$d/src/lib.rs"
    list="$(make_list "$d/l" "$d/src/lib.rs")"
    assert_silent "$SK_TEST" missing-test-file \
        "tested: a Rust file with inline #[cfg(test)] suppresses missing-test-file" -- "$list"

    # ...and a bare .rs with NEITHER cfg(test) NOR a ../tests dir fires...
    d="$(fresh_dir)"
    command mkdir -p "$d/src"
    command printf '%s\n' 'fn other() {}' >"$d/src/bare.rs"
    list="$(make_list "$d/l" "$d/src/bare.rs")"
    assert_fires "$SK_TEST" missing-test-file "No test file found" \
        "tested: a bare .rs with no cfg(test)/../tests fires missing-test-file" -- "$list"

    # ...but the same bare .rs beside a ../tests directory is suppressed (isdir arm).
    command mkdir -p "$d/tests"
    assert_silent "$SK_TEST" missing-test-file \
        "tested: a bare .rs beside a ../tests dir suppresses missing-test-file (isdir arm)" -- "$list"
}

# ============================================================================
# loop-make-it-documented — undocumented function / class / export (+ shell)
# ============================================================================
test_documented_python() {
    local d list

    # undocumented-public-function: a py def with no docstring fires...
    d="$(fresh_dir)"
    command printf '%s\n' 'def compute():' '    return 0' >"$d/f.py"
    list="$(make_list "$d/l" "$d/f.py")"
    assert_fires "$SK_DOC" undocumented-public-function "No docstring" \
        "documented: an undocumented py def fires" -- "$list"

    # ...but a def WITH a docstring stays silent (docstring boundary).
    d="$(fresh_dir)"
    command printf '%s\n' 'def compute():' '    """Compute it."""' '    return 0' >"$d/g.py"
    list="$(make_list "$d/l" "$d/g.py")"
    assert_silent "$SK_DOC" undocumented-public-function \
        "documented: a py def with a docstring stays silent" -- "$list"

    # BOUNDARY: a def followed by a BLANK line then the docstring stays silent
    # (the blank-skip loop advances past the blank before checking).
    d="$(fresh_dir)"
    command printf '%s\n' 'def compute():' '' '    """Doc after a blank."""' '    return 0' >"$d/h.py"
    list="$(make_list "$d/l" "$d/h.py")"
    assert_silent "$SK_DOC" undocumented-public-function \
        "documented: a docstring after a blank line stays silent (blank-skip boundary)" -- "$list"

    # undocumented-public-class: a py class with no docstring fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'class Widget:' '    x = 1' >"$d/c.py"
    list="$(make_list "$d/l" "$d/c.py")"
    assert_fires "$SK_DOC" undocumented-public-class "No docstring" \
        "documented: an undocumented py class fires" -- "$list"
}

test_documented_other_langs() {
    local d list

    # undocumented-export: a JS `export function` with no preceding JSDoc fires.
    # (A leading line keeps the export off line 1 — scan_js only inspects a def
    # with a real predecessor line, `if prev > 0`.)
    d="$(fresh_dir)"
    command printf '%s\n' 'const x = 1;' 'export function doThing() {}' >"$d/e.js"
    list="$(make_list "$d/l" "$d/e.js")"
    assert_fires "$SK_DOC" undocumented-export "No JSDoc" \
        "documented: an undocumented JS export fires" -- "$list"

    # ...and a JS `export class` routes to undocumented-public-class (category split).
    d="$(fresh_dir)"
    command printf '%s\n' 'const y = 2;' 'export class Thing {}' >"$d/e2.js"
    list="$(make_list "$d/l" "$d/e2.js")"
    assert_fires "$SK_DOC" undocumented-public-class "No JSDoc" \
        "documented: an undocumented JS export class fires the class category" -- "$list"

    # BOUNDARY: a JS export preceded by a JSDoc close line `*/` stays silent (the
    # preceding line must itself match `^\s*\*/`, i.e. a multi-line JSDoc close —
    # a single-line `/** ... */` would not).
    d="$(fresh_dir)"
    command printf '%s\n' '/**' ' * Does the thing.' ' */' 'export function doThing() {}' >"$d/e3.js"
    list="$(make_list "$d/l" "$d/e3.js")"
    assert_silent "$SK_DOC" undocumented-export \
        "documented: a JS export with a JSDoc block stays silent" -- "$list"

    # undocumented-export: a Go exported func with no GoDoc comment fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'package p' 'func DoThing() {}' >"$d/g.go"
    list="$(make_list "$d/l" "$d/g.go")"
    assert_fires "$SK_DOC" undocumented-export "No GoDoc for DoThing" \
        "documented: an undocumented Go exported func fires" -- "$list"

    # ...but a Go func with a `// DoThing` GoDoc line stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' 'package p' '// DoThing does the thing.' 'func DoThing() {}' >"$d/g2.go"
    list="$(make_list "$d/l" "$d/g2.go")"
    assert_silent "$SK_DOC" undocumented-export \
        "documented: a Go func with a GoDoc comment stays silent" -- "$list"

    # undocumented-public-function: a shell function with no preceding comment fires.
    d="$(fresh_dir)"
    command printf '%s\n' 'x=1' 'deploy() {' '  true' '}' >"$d/s.sh"
    list="$(make_list "$d/l" "$d/s.sh")"
    assert_fires "$SK_DOC" undocumented-public-function "No comment before function" \
        "documented: an uncommented shell function fires" -- "$list"

    # ...but a shell function with a preceding `#` comment stays silent.
    d="$(fresh_dir)"
    command printf '%s\n' '# deploy the app' 'deploy() {' '  true' '}' >"$d/s2.sh"
    list="$(make_list "$d/l" "$d/s2.sh")"
    assert_silent "$SK_DOC" undocumented-public-function \
        "documented: a commented shell function stays silent" -- "$list"
}

# ============================================================================
# drift-detect — planned-not-touched / unplanned-modification (two-arg)
# ============================================================================
test_drift_categories() {
    local d actual planned

    d="$(fresh_dir)"
    # planned foo.py is touched; bar.py is planned but absent from the diff;
    # unlisted.py is unplanned (MEDIUM); package-lock.json is a side-effect (LOW);
    # test_foo.py is a test for planned foo.py (LOW). A blank + whitespace-only
    # line in each list exercises the skip arms.
    actual="$(make_list "$d/actual" \
        "src/foo.py" "src/unlisted.py" "package-lock.json" "src/test_foo.py" "" "   ")"
    planned="$(make_list "$d/planned" "src/foo.py" "src/bar.py" "" "   ")"

    assert_fires "$SK_DRIFT" planned-not-touched "Planned file not found" \
        "drift: a planned-but-untouched file fires planned-not-touched" -- "$actual" "$planned"
    assert_fires "$SK_DRIFT" unplanned-modification "not listed in plan" \
        "drift: an unlisted change fires unplanned-modification MEDIUM" -- "$actual" "$planned"
    assert_fires "$SK_DRIFT" unplanned-modification "side-effect or test" \
        "drift: a side-effect / test change fires unplanned-modification LOW" -- "$actual" "$planned"
}

test_drift_clean() {
    local d actual planned

    # Every planned file is touched and nothing extra changed → no findings.
    d="$(fresh_dir)"
    actual="$(make_list "$d/actual" "src/foo.py")"
    planned="$(make_list "$d/planned" "src/foo.py")"
    assert_silent "$SK_DRIFT" planned-not-touched \
        "drift: a fully-covered plan emits no planned-not-touched" -- "$actual" "$planned"
    assert_silent "$SK_DRIFT" unplanned-modification \
        "drift: a fully-covered plan emits no unplanned-modification" -- "$actual" "$planned"
}

run_test test_work_stub_and_body "loop-make-it-work: stub + py/js/go empty-body + EOF boundary"
run_test test_work_no_assertions "loop-make-it-work: py/js/go no-assertions + has-assert negative"
run_test test_right_long_function "loop-make-it-right: py + brace long-function (colon-stripped)"
run_test test_right_deep_nesting "loop-make-it-right: deep-nesting emit"
run_test test_right_single_char "loop-make-it-right: single-char fires + loop-counter/'_' skips"
run_test test_secure_secret "loop-make-it-secure: keyed + AWS secret + *test* SKIP_GLOBS"
run_test test_secure_interpolation "loop-make-it-secure: py/js/go interpolation-query"
run_test test_secure_dangerous_and_denylist "loop-make-it-secure: dangerous-fn + yaml Loader boundary + denylist"
run_test test_tested_missing_and_untested "loop-make-it-tested: missing-test + untested-api + sibling boundaries"
run_test test_tested_module_public_symbol_gate "loop-make-it-tested: main()-guard / __all__ public-symbol selection (#606)"
run_test test_tested_ts_and_rust "loop-make-it-tested: ts/js + rust missing-test-file probe arms"
run_test test_documented_python "loop-make-it-documented: py function/class + docstring + blank-skip"
run_test test_documented_other_langs "loop-make-it-documented: js/go/shell arms + documented negatives"
run_test test_drift_categories "drift-detect: planned-not-touched + MEDIUM/LOW unplanned + skips"
run_test test_drift_clean "drift-detect: a fully-covered plan stays silent"

generate_report
