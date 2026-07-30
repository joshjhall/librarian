# shellcheck shell=bash
# dev-core loop-* + drift-detect corpus — python coverage fixtures (issue #564 split).
#
# Builds the per-loop fixtures and the planned-vs-actual path lists (#384).
#
# Sourced by tests/coverage-python.sh, which creates WORKDIR and its EXIT trap
# BEFORE this file. This fragment only BUILDS FIXTURES and exports the path-list
# variables the driver section then feeds to each port under `coverage run`.
#
# NOTE: unlike the tests/ fragments, nothing here asserts — coverage-python.sh is
# a Codecov driver, not a test suite (it has zero run_test calls and is not wired
# into tests/run-all.sh). The behavioural gates for these same detectors live in
# tests/validate-{source,docs,loop,lifecycle,checker}-detectors.sh, and this
# corpus is kept in lockstep with them.

# The path-list / fixture-path variables below are the corpus's EXPORT surface:
# they are read by the driver loop in tests/coverage-python.sh, which sources
# this file. shellcheck analyses one file at a time and so cannot see those
# uses.
# shellcheck disable=SC2034  # consumed by the driver in tests/coverage-python.sh

# --- dev-core loop-* + drift corpus (#384) ----------------------------------
# The six dev-core ports (loop-make-it-work/right/secure/tested/documented +
# drift-detect) were the lowest-coverage ports left after the source slice #383
# (66–80%) because the generic corpus above never exercised their per-language /
# per-framework / boundary / negative arms. These fixtures drive those branches
# under measurement, in lockstep with the behavioral assertions in
# tests/validate-loop-detectors.sh (the #204 two-surface convention). The five
# loop ports each take a single file-list; drift-detect is the two-arg outlier
# (handled by its existing driver, extended below). loop-make-it-tested probes
# the working tree (sibling test files) via each path's own dirname, so its
# fixtures live in a sibling-populated tree; absolute paths make CWD irrelevant.
# Boundary/negative arms (the EOF empty-body return, the has-assert negative, the
# single-char skips, the yaml Loader= exclusion, the SKIP_GLOBS whole-file skip,
# the sibling-present suppression, the documented negatives, the per-file OSError
# and file-list-not-found arms) are all represented so their lines execute;
# correctness is pinned by the gate.
LOOPDIR="$FIXDIR/loop"
mkdir -p "$LOOPDIR"

# Fake secrets assembled from fragments so this SCRIPT holds no contiguous secret
# for gitleaks; the fixtures on disk carry the full tokens (obvious fake filler).
LOOP_AKIA="AKIA""0123456789ABCDEF"
LOOP_SECRET="abcdefgh""ijklmnop1234"

# loop-make-it-work: stub, per-language empty-body, a trailing `def` (EOF
# _first_nonblank_after '' return), and per-language test files with no assertions
# (py/js/go emits) plus a py test file WITH an assert (the has-assert negative).
{
    printf '%s\n' 'def stub():  # TODO: finish'
    printf '%s\n' '    raise NotImplementedError'
    printf '%s\n' 'def empty():'
    printf '%s\n' '    pass'
    printf '%s\n' 'def trailing():'
} >"$LOOPDIR/work.py"
printf '%s\n' 'const f = () => {}' >"$LOOPDIR/work.js"
printf '%s\n' 'func Noop() {}' >"$LOOPDIR/work.go"
printf '%s\n' 'def test_none():' '    do_thing()' >"$LOOPDIR/test_noassert.py"
printf '%s\n' 'def test_ok():' '    assert do_thing()' >"$LOOPDIR/test_withassert.py"
printf '%s\n' 'it("x", () => { run(); });' >"$LOOPDIR/widget.test.ts"
printf '%s\n' 'package p' 'func TestX(t *testing.T) { run() }' >"$LOOPDIR/widget_test.go"

# loop-make-it-right: a long py function (colon-stripped evidence) + a long brace
# function; a deeply-nested line; a flagged single-char `z`; a skipped loop-counter
# `x`; a skipped `_ =` throwaway. Thresholds are forced via env at run time.
# `top = 1` at column 0 after the def gives the long-function end-of-function
# dedent match (the `end_off` break arm) rather than the run-to-EOF fallback.
{
    printf '%s\n' 'def longfn():'
    printf '%s\n' '    a()'
    printf '%s\n' '    b()'
    printf '%s\n' 'top = 1'
} >"$LOOPDIR/long.py"
printf '%s\n' 'function foo() {' '  x()' '}' 'function bar() {' '  y()' '}' >"$LOOPDIR/long.js"
# A `.rb` file (neither py nor a BRACE_EXTS lang) drives scan_deep_nesting's
# `else: return` early arm; single-char is py-only so it emits nothing here.
printf '%s\n' 'x = 1' >"$LOOPDIR/other.rb"
# single-char: a flagged `z`, a skipped loop-counter `x`, a `_ =` throwaway, and a
# chained `a = _ = ...` (the PY_SINGLE_SKIP_RE `_\s*=` arm on a non-leading `_`).
{
    printf '%s\n' '    z = compute()'
    printf '%s\n' '    x = counter()'
    printf '%s\n' '    _ = throwaway()'
    printf '%s\n' '    a = _ = chained()'
} >"$LOOPDIR/single.py"

# loop-make-it-secure: keyed secret + AWS key + per-language interpolation-query
# (py/js/go) + subprocess shell=True + yaml.load without Loader (fires) + with
# Loader (silent) + a blacklist array (denylist). A separate *test* file carrying a
# secret drives the SKIP_GLOBS whole-file skip.
{
    printf 'api_key = "%s"\n' "$LOOP_SECRET"
    printf 'aws = "%s"\n' "$LOOP_AKIA"
    printf '%s\n' 'cur.execute(f"SELECT * FROM t WHERE id={i}")'
    printf '%s\n' 'subprocess.call(cmd, shell=True)'
    printf '%s\n' 'a = yaml.load(payload)'
    printf '%s\n' 'b = yaml.load(payload, Loader=SafeLoader)'
    printf '%s\n' 'blacklist = ["a", "b"]'
} >"$LOOPDIR/sec.py"
printf '%s\n' 'db.query(`SELECT * FROM t WHERE x=${v}`);' >"$LOOPDIR/sec.js"
printf '%s\n' 'db.Query(fmt.Sprintf("SELECT %s", x))' >"$LOOPDIR/sec.go"
printf 'api_key = "%s"\n' "$LOOP_SECRET" >"$LOOPDIR/sec_test.py"

# loop-make-it-tested: a sibling-populated tree. mod.py has no sibling (missing +
# untested fire); mod2.py has a referencing sibling (has_test break + untested
# silent); comp.ts has a *.test.ts sibling (js probe); svc.go has a _test.go that
# does NOT reference DoThing (go has_test + go untested emit); lib.rs carries a
# `#[cfg(test)]` inline (rs inline arm); lib2.rs sits beside a ../tests dir (rs
# isdir arm). The tree dir is named `probe` (NOT `tested`): loop-make-it-tested's
# SKIP_GLOBS matches `*test*` on the whole path, so a `tested/` segment would skip
# every fixture wholesale.
TSTDIR="$LOOPDIR/probe/src"
mkdir -p "$TSTDIR" "$LOOPDIR/probe/tests"
printf '%s\n' 'def public_fn():' '    return 0' >"$TSTDIR/mod.py"
printf '%s\n' 'def other_fn():' '    return 0' >"$TSTDIR/mod2.py"
printf '%s\n' 'def test_it():' '    other_fn()' >"$TSTDIR/test_mod2.py"
printf '%s\n' 'export const c = 1;' >"$TSTDIR/comp.ts"
printf '%s\n' 'test("c", () => {});' >"$TSTDIR/comp.test.ts"
# svc.go exports two funcs: DoThing IS referenced by svc_test.go (the
# _word_in_file `return True` arm → untested silent) while DoOther is NOT (the
# run-to-EOF `return False` arm → untested fires).
printf '%s\n' 'package p' 'func DoThing() {}' 'func DoOther() {}' >"$TSTDIR/svc.go"
printf '%s\n' 'package p' 'func TestIt(t *testing.T) { DoThing() }' >"$TSTDIR/svc_test.go"
printf '%s\n' 'fn thing() {}' '#[cfg(test)]' 'mod tests {}' >"$TSTDIR/lib.rs"
printf '%s\n' 'fn other() {}' >"$TSTDIR/lib2.rs"
# gomod.go has an UNREADABLE sibling _test.go: os.path.isfile() passes but
# _word_in_file's open() raises OSError → its `except OSError: return False` arm →
# untested-public-api fires. pymod.py has an UNREADABLE test_*.py glob match:
# _word_in_any's open() raises OSError → its `except OSError: continue` arm.
printf '%s\n' 'package p' 'func GoFn() {}' >"$TSTDIR/gomod.go"
printf '%s\n' 'unreadable' >"$TSTDIR/gomod_test.go"
chmod 000 "$TSTDIR/gomod_test.go" 2>/dev/null || true
printf '%s\n' 'def py_fn():' '    return 0' >"$TSTDIR/pymod.py"
printf '%s\n' 'unreadable' >"$TSTDIR/test_pymod.py"
chmod 000 "$TSTDIR/test_pymod.py" 2>/dev/null || true
# A *.md file drives the tested-port SKIP_GLOBS whole-file skip arm.
printf '%s\n' '# notes' >"$TSTDIR/notes.md"

# loop-make-it-documented: an undocumented py def + py class + a def whose
# docstring follows a BLANK line (blank-skip arm, stays silent); a JS export
# (preceded by a line so `prev > 0`); a Go exported func + one with a GoDoc line;
# a shell function + one with a preceding `#` comment.
# doc.py: an undocumented def; a def whose docstring follows a BLANK line (the def
# blank-skip loop); an undocumented class; and a class whose docstring follows a
# BLANK line (the class blank-skip loop body).
{
    printf '%s\n' 'def undocumented():'
    printf '%s\n' '    return 0'
    printf '%s\n' 'def documented():'
    printf '%s\n' ''
    printf '%s\n' '    """Doc after a blank."""'
    printf '%s\n' '    return 0'
    printf '%s\n' 'class Widget:'
    printf '%s\n' '    x = 1'
    printf '%s\n' 'class Documented:'
    printf '%s\n' ''
    printf '%s\n' '    """Class doc after a blank."""'
} >"$LOOPDIR/doc.py"
printf '%s\n' 'const x = 1;' 'export function doThing() {}' 'export class Thing {}' >"$LOOPDIR/doc.js"
# A TS export drives the JS/Go/Shell export arm. Its signature ends in a lone
# `:` on purpose: that shape used to be eaten by the `IFS=:` read and by the
# `_bash_read_content` shim that cloned the strip into Python (#549, both now
# gone). Keep the trailing colon so the arm stays exercised on the shape that
# regressed twice.
printf '%s\n' 'const z = 1;' 'export function parse():' >"$LOOPDIR/doc.ts"
printf '%s\n' 'package p' 'func Bare() {}' '// Named does it.' 'func Named() {}' >"$LOOPDIR/doc.go"
printf '%s\n' 'x=1' 'bare() {' '  true' '}' '# commented' 'named() {' '  true' '}' >"$LOOPDIR/doc.sh"
# A *.md file drives the documented-port SKIP_GLOBS whole-file skip arm.
printf '%s\n' '# a markdown heading' >"$LOOPDIR/doc-notes.md"

# Per-port file lists. A leading blank line in each drives the `if not path`
# empty-token skip; a trailing ghost path drives the isfile()==False skip arm.
LOOP_GHOST="$LOOPDIR/does-not-exist-XYZ.py"
LOOP_WORK_LIST="$WORKDIR/loop-work-list.txt"
printf '%s\n' "" "$LOOPDIR/work.py" "$LOOPDIR/work.js" "$LOOPDIR/work.go" \
    "$LOOPDIR/test_noassert.py" "$LOOPDIR/test_withassert.py" \
    "$LOOPDIR/widget.test.ts" "$LOOPDIR/widget_test.go" "$LOOP_GHOST" >"$LOOP_WORK_LIST"
LOOP_RIGHT_LIST="$WORKDIR/loop-right-list.txt"
printf '%s\n' "" "$LOOPDIR/long.py" "$LOOPDIR/long.js" "$LOOPDIR/other.rb" \
    "$LOOPDIR/single.py" "$LOOP_GHOST" >"$LOOP_RIGHT_LIST"
LOOP_SEC_LIST="$WORKDIR/loop-sec-list.txt"
printf '%s\n' "" "$LOOPDIR/sec.py" "$LOOPDIR/sec.js" "$LOOPDIR/sec.go" \
    "$LOOPDIR/sec_test.py" "$LOOP_GHOST" >"$LOOP_SEC_LIST"
LOOP_TEST_LIST="$WORKDIR/loop-test-list.txt"
printf '%s\n' "" "$TSTDIR/mod.py" "$TSTDIR/mod2.py" "$TSTDIR/comp.ts" \
    "$TSTDIR/svc.go" "$TSTDIR/lib.rs" "$TSTDIR/lib2.rs" \
    "$TSTDIR/gomod.go" "$TSTDIR/pymod.py" "$TSTDIR/notes.md" \
    "$LOOP_GHOST" >"$LOOP_TEST_LIST"
LOOP_DOC_LIST="$WORKDIR/loop-doc-list.txt"
printf '%s\n' "" "$LOOPDIR/doc.py" "$LOOPDIR/doc.js" "$LOOPDIR/doc.ts" \
    "$LOOPDIR/doc.go" "$LOOPDIR/doc.sh" "$LOOPDIR/doc-notes.md" \
    "$LOOP_GHOST" >"$LOOP_DOC_LIST"

# An unreadable source file (passes isfile, fails open) drives the per-file
# OSError read arm in every loop port. chmod 000 only denies a NON-root reader.
LOOP_UNREAD="$LOOPDIR/unreadable.py"
printf '%s\n' 'def public_fn():' '    return 0' >"$LOOP_UNREAD"
chmod 000 "$LOOP_UNREAD" 2>/dev/null || true
LOOP_UNREAD_LIST="$WORKDIR/loop-unread-list.txt"
printf '%s\n' "$LOOP_UNREAD" >"$LOOP_UNREAD_LIST"

# A file-list PATH that itself does not exist drives the file-list-not-found
# (OSError) arm in every loop port.
LOOP_NOFILE_LIST="$WORKDIR/loop-nonexistent-list-XYZ.txt"

# drift-detect extension (#384): the existing DRIFT_ACTUAL/DRIFT_PLANNED lists
# (above) cover planned-not-touched + unplanned MEDIUM. Add a side-effect
# (package-lock.json → LOW), a test-for-planned (test_foo.py for planned foo.py →
# LOW break arm), and blank/whitespace-only lines (the trim skip arms) so those
# branches execute. A fully-covered pair and the usage / list-not-found arms are
# driven in drift's case arm below.
DRIFT_ACTUAL2="$WORKDIR/drift-actual2.txt"
DRIFT_PLANNED2="$WORKDIR/drift-planned2.txt"
printf '%s\n' "src/foo.py" "src/unlisted.py" "package-lock.json" "src/test_foo.py" \
    "" "   " >"$DRIFT_ACTUAL2"
printf '%s\n' "src/foo.py" "src/bar.py" "" "   " >"$DRIFT_PLANNED2"
DRIFT_NOFILE="$WORKDIR/drift-nonexistent-XYZ.txt"
