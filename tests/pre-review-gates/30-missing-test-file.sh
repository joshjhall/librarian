# shellcheck shell=bash
# Category: missing-test-file — repo-rooted probes, is_test_file, declared conventions, stdout_is_output, .mjs/.cjs
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Category: missing-test-file --------------------------------------------

# A .py source with no sibling/tests/ test file must produce a missing-test-file
# row at line 1 with HIGH certainty. The scratch dir has no tests/ tree so none
# of the lookup paths resolve.
test_missing_test_file_fires() {
    local d rows row
    d="$(fresh_dir)"
    command printf '%s\n' "x = 1" >"$d/orphan.py"
    run_gate "$(make_list "$d" orphan.py)"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_empty "$rows" "orphan source must emit a missing-test-file row"
    row="$(command printf '%s\n' "$rows" | command head -1)"
    assert_equals "1" "$(field "$row" 2)" "missing-test-file anchors at line 1"
    assert_equals "HIGH" "$(field "$row" 5)" "missing test for a source file is HIGH"
}

# --- missing-test-file: repo-rooted tests/ for js/ts (#555) -----------------

# The headline #555 case. A .js source whose ONLY test lives under a repo-rooted
# tests/ tree, with a DIFFERENT extension (.mjs), must not emit
# missing-test-file. Before the fix the js/ts arm probed only three colocated
# paths and interpolated the source's own extension into each, so this file was
# reported HIGH despite being tested.
#
# A control source in the same run — same tree, same run, no matching test —
# must still fire, so a pass cannot come from the scanner going silent.
test_repo_rooted_js_test_detected() {
    local sb list tested control
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "const thing = 1;" >"$sb/src/thing.js"
    command printf '%s\n' "// exercises thing.js" >"$sb/tests/validate-thing-helpers.mjs"
    command printf '%s\n' "const lonely = 1;" >"$sb/src/lonely.js"

    list="$sb/files.txt"
    command printf '%s\n' "$sb/src/thing.js" "$sb/src/lonely.js" >"$list"

    run_gate_in "$sb" "$list"

    tested="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'thing\.js' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.js' || true)"

    assert_equals "0" "$tested" \
        "a .js source tested by tests/validate-<name>-*.mjs emits no missing-test-file"
    assert_equals "1" "$control" \
        "an untested .js source in the same run still emits missing-test-file"
}

# EVERY (stem x suffix-form) alternative the repo-rooted probe builds, so a
# typo isolated to any single `find_args` entry has a test that fails.
#
# has_repo_rooted_js_test emits three `-name` alternatives per stem per
# extension: `<stem>.<ext>`, `<stem>-*.<ext>`, `<stem>_*.<ext>`, over 6 stems.
# Sampling one exemplar per stem (the first version of this case) left the two
# WILDCARD alternatives of five stems unexercised — the comment claimed
# exhaustiveness the coverage did not have. This walks all 6 x 3 = 18
# alternatives explicitly.
#
# The extension is ROTATED across the js/mjs/cjs/ts/tsx/jsx family as the walk
# proceeds rather than pinned, so every extension in the allowlist is exercised
# too, and every row is a cross-extension case (source is always .js except the
# reverse-direction row below).
#
# Each row runs in its own sandbox holding exactly ONE test file, so a match can
# only come from the alternative under test.
test_repo_rooted_stem_forms_all_match() {
    local sb rows stem form fname ext i=0
    local exts="js mjs cjs ts tsx jsx"
    local stems="thing.test thing.spec test-thing test_thing spec-thing validate-thing"

    for stem in $stems; do
        for form in exact hyphen underscore; do
            # Rotate the extension so the allowlist is covered as we go.
            ext="$(command printf '%s' "$exts" | command cut -d' ' -f$(((i % 6) + 1)))"
            i=$((i + 1))
            case "$form" in
                exact) fname="${stem}.${ext}" ;;
                hyphen) fname="${stem}-helpers.${ext}" ;;
                underscore) fname="${stem}_helpers.${ext}" ;;
            esac

            new_git_sandbox sb
            command mkdir -p "$sb/src" "$sb/tests"
            command printf '%s\n' "const x = 1;" >"$sb/src/thing.js"
            command printf '%s\n' "// covers thing.js" >"$sb/tests/${fname}"
            command printf '%s\n' "$sb/src/thing.js" >"$sb/files.txt"

            run_gate_in "$sb" "$sb/files.txt"

            rows="$(category_rows "$GATE_OUT" "missing-test-file" || true)"
            assert_output_empty "$rows" \
                "tests/${fname} covers thing.js (${stem}, ${form} form)"
        done
    done

    # Reverse cross-extension direction: a .ts source found by a .js test. Every
    # row above is a .js source, so without this the fix's claim that the search
    # is independent of the SOURCE's extension is only half proven.
    new_git_sandbox sb
    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "const c = 1;" >"$sb/src/comp.ts"
    command printf '%s\n' "// covers comp.ts" >"$sb/tests/validate-comp-helpers.js"
    command printf '%s\n' "$sb/src/comp.ts" >"$sb/files.txt"
    run_gate_in "$sb" "$sb/files.txt"
    rows="$(category_rows "$GATE_OUT" "missing-test-file" || true)"
    assert_output_empty "$rows" \
        "reverse cross-extension: .ts source covered by a .js test"
}

# The extension allowlist must be a REAL filter, not documented intent. A test
# file with a correct stem but an out-of-family extension (.py) must NOT satisfy
# the probe — otherwise `find`'s matching could be succeeding for some reason
# other than the explicit per-extension `-name` patterns, and every positive
# case above would pass for the wrong reason.
test_repo_rooted_probe_rejects_foreign_extensions() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "const thing = 1;" >"$sb/src/thing.js"
    # Right stem, wrong family — a python test does not cover a js source here.
    command printf '%s\n' "# not a js test" >"$sb/tests/thing.test.py"
    command printf '%s\n' "$sb/src/thing.js" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_empty "$rows" \
        "a same-stem .py file does not satisfy the js/ts extension allowlist"
}

# A DIRECTORY whose name matches a test stem must NOT satisfy the probe.
# `find` matches directories too, so without `-type f` a snapshot/fixture dir
# like `tests/validate-thing-snapshots.js/` suppresses a genuine
# missing-test-file row — a false negative that hides the very bug this
# scanner reports. Raised by review cycle 1 (correctness) and confirmed by
# direct probe before fixing.
test_repo_rooted_probe_ignores_directories() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "const thing = 1;" >"$sb/src/thing.js"
    # A directory, not a file — named exactly like a matching test would be.
    command mkdir -p "$sb/tests/validate-thing-snapshots.js"
    command printf '%s\n' "$sb/src/thing.js" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_empty "$rows" \
        "a directory named like a test does not suppress missing-test-file"
}

# Regression guard for the pre-existing colocated path (#555 AC#4). The
# repo-rooted fallback is additive; the <name>.test.<ext> sibling convention
# must keep resolving on its own, in a tree with no tests/ dir at all.
test_colocated_js_test_still_detected() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "const widget = 1;" >"$d/widget.js"
    command printf '%s\n' "// tests widget" >"$d/widget.test.js"
    run_gate "$(make_list "$d" widget.js)"

    rows="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep 'widget\.js' || true)"
    assert_output_empty "$rows" \
        "colocated widget.test.js still suppresses missing-test-file"
}

# True negative: the repo-rooted probe must stay ANCHORED to the source name.
# A tests/ tree full of unrelated tests must not satisfy an untested source —
# this is the case that fails if the find expression is widened into a rubber
# stamp that matches any test file in the tree.
test_repo_rooted_probe_is_name_anchored() {
    local sb list rows row
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "const orphan = 1;" >"$sb/src/orphan.js"
    # Populated tests/ tree — none of these names derive from "orphan".
    command printf '%s\n' "// unrelated" >"$sb/tests/validate-something-else.mjs"
    command printf '%s\n' "// unrelated" >"$sb/tests/other.test.js"

    list="$sb/files.txt"
    command printf '%s\n' "$sb/src/orphan.js" >"$list"

    run_gate_in "$sb" "$list"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_empty "$rows" \
        "a non-empty tests/ tree with no name-matching test still emits missing-test-file"
    row="$(command printf '%s\n' "$rows" | command head -1)"
    assert_equals "HIGH" "$(field "$row" 5)" \
        "an genuinely untested js source stays HIGH"
}

# #555 AC#3 + #568, asserted against THIS repo rather than a fixture: the real
# ship-issue workflow.js is covered by tests/workflow-helpers/ship-issue.mjs and
# tests/validate-workflow-helpers.mjs, so it must emit NO rows at all.
#
# BOUNDARY HISTORY — this case is the ratchet, read it before editing.
# Under #555 only `missing-test-file` was fixed, and this case deliberately
# asserted `untested-public-api` was STILL present, with a note saying that if
# #568 later silenced it, the assertion should be updated deliberately rather
# than by accident. #568 did exactly that — the cross-directory fallback in
# scan_untested_public_api now finds `meta` referenced from the repo-rooted
# helpers — so the assertion is now "no rows in EITHER category". The ratchet
# worked as designed: the change announced itself as a failing test.
#
# MAINTAINER NOTE: this is the one case in the suite that reads the LIVE repo
# rather than a fixture — AC#3 asks for exactly that, so the coupling is
# deliberate. It does not hardcode a test filename (any of the six stems
# satisfies it), but renaming or relocating the helper modules that cover
# ship-issue/workflow.js out of tests/ WILL turn this red for a reason
# unrelated to a scanner regression. Fix the layout or the assertion — do not
# delete the case.
test_real_repo_workflow_js_not_flagged() {
    local d list missing api
    d="$(fresh_dir)"
    list="$d/files.txt"
    command printf '%s\n' \
        "$REPO_ROOT/plugins/workflow/skills/ship-issue/workflow.js" >"$list"

    run_gate_in "$REPO_ROOT" "$list"

    missing="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'workflow\.js' || true)"
    api="$(category_rows "$GATE_OUT" "untested-public-api" |
        command grep -c 'workflow\.js' || true)"

    assert_equals "0" "$missing" \
        "this repo's ship-issue/workflow.js emits no missing-test-file (#555 AC#3)"
    assert_equals "0" "$api" \
        "and no untested-public-api either — the cross-dir fallback sees the helpers (#568)"
}

# --- #568: is_test_file basename anchoring ----------------------------------

# A bash `case` glob's `*` crosses `/`, so the old path arm `*/test_*.*` also
# matched a DIRECTORY named `test_helpers/` — silencing EVERY scanner for real
# production source inside it. The name arms now match the basename, so only a
# genuine `tests/`-style DIRECTORY segment skips a file.
#
# This is the case that fails against the pre-#568 scanner. It also pins the
# other side: a real test dir and a real test_-prefixed FILE must still skip.
test_is_test_file_anchors_on_basename() {
    local d rows
    d="$(fresh_dir)"
    command mkdir -p "$d/src/test_helpers" "$d/tests"

    # Production source living under a test_-PREFIXED DIRECTORY: must be scanned.
    command printf '%s\n' "def public_thing(a):" "    return a" \
        >"$d/src/test_helpers/production.py"
    # A real test FILE and a real tests/ DIRECTORY: must still be skipped.
    command printf '%s\n' "def test_x():" "    assert True" >"$d/test_util.py"
    command printf '%s\n' "def helper():" "    pass" >"$d/tests/helper.py"

    run_gate "$(make_list "$d" src/test_helpers/production.py test_util.py tests/helper.py)"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_contains "$rows" "production.py" \
        "source under a test_-prefixed DIRECTORY is scanned, not skipped (#568)"
    assert_not_contains "$rows" "test_util.py" \
        "a genuine test_-prefixed FILE is still skipped"
    assert_not_contains "$rows" "helper.py" \
        "a file under a real tests/ directory is still skipped"
}

# --- #605: is_test_file, both branches, arm by arm --------------------------

# is_test_file had no direct both-branch coverage: it was exercised only
# indirectly, and the bash<->python parity fixture asserts the two impls AGREE,
# not that either is CORRECT — if both share a misconception, parity stays green
# and both are wrong (#605). The case above covers two arms via
# missing-test-file; these two cover the REST, through debug-statement, which is
# the category is_test_file actually gates.
#
# Both directions are pinned from one fixture per case, so neither can pass by
# the scanner having gone silent.

# TRUE branch — every directory-segment and basename arm must SKIP.
test_is_test_file_true_branch_all_arms() {
    local d rows
    d="$(fresh_dir)"
    command mkdir -p "$d/spec" "$d/__tests__" "$d/pkg/test"

    # One debug statement per arm; each must be suppressed as a test file.
    command printf '%s\n' "console.log('in spec dir');" >"$d/spec/a.js"
    command printf '%s\n' "console.log('in __tests__ dir');" >"$d/__tests__/b.js"
    command printf '%s\n' "console.log('in nested test dir');" >"$d/pkg/test/c.js"
    command printf '%s\n' "console.log('name arm _test');" >"$d/thing_test.js"
    command printf '%s\n' "console.log('name arm .spec');" >"$d/thing.spec.js"
    # ...and a non-test file proving the scanner is alive on this same run.
    command printf '%s\n' "console.log('real source');" >"$d/app.js"

    run_gate "$(make_list "$d" spec/a.js __tests__/b.js pkg/test/c.js \
        thing_test.js thing.spec.js app.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_contains "$rows" "spec/a.js" "spec/ segment is a test path (#605)"
    assert_not_contains "$rows" "__tests__/b.js" "__tests__/ segment is a test path (#605)"
    assert_not_contains "$rows" "pkg/test/c.js" "a nested test/ segment is a test path (#605)"
    assert_not_contains "$rows" "thing_test.js" "*_test.* basename is a test file (#605)"
    assert_not_contains "$rows" "thing.spec.js" "*.spec.* basename is a test file (#605)"
    # The liveness half: without this, every assertion above passes vacuously if
    # the debug detector breaks entirely.
    assert_contains "$rows" "app.js" \
        "...while ordinary source in the same run still fires (#605 liveness)"
}

# FALSE branch — the near-miss names #568 fixed must NOT be treated as tests.
# These are the ones a loose `*test*` glob wrongly swallows, silencing real
# source; each must still emit its debug row.
test_is_test_file_false_branch_near_misses() {
    local d rows
    d="$(fresh_dir)"
    command mkdir -p "$d/src/protest"

    command printf '%s\n' "print('contest')" >"$d/contest.py"
    command printf '%s\n' "console.log('latest');" >"$d/latest.js"
    command printf '%s\n' "console.log('manifesto');" >"$d/src/protest/manifest.js"

    run_gate "$(make_list "$d" contest.py latest.js src/protest/manifest.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "contest.py" \
        "contest.py is NOT a test file — its debug print fires (#605)"
    assert_contains "$rows" "latest.js" \
        "latest.js is NOT a test file — its debug log fires (#605)"
    assert_contains "$rows" "src/protest/manifest.js" \
        "a protest/ directory is NOT a test segment — source under it is scanned (#605)"
}

# --- #568: declared conventions from .claude/pre-review.yml -----------------

# `test_patterns` declares files that ARE tests; `test_discovery` declares how
# to find the test FOR a source. Together they are the supported escape hatch
# for a convention the built-in heuristics cannot infer — deliberately chosen
# over widening the heuristics, because a wrongly-inferred test is a SILENT
# false negative.
#
# Mirrors the issue's real repro: tests named scripts/smoke-<name>.ts.
test_declared_test_conventions_honored() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' \
        "test_patterns:" \
        "  - 'scripts/smoke-*.ts'" \
        "test_discovery:" \
        "  - 'scripts/smoke-{name}.ts'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' "export function buildReport() {}" >"$sb/scripts/token-report.ts"
    command printf '%s\n' "import {buildReport} from './token-report';" \
        >"$sb/scripts/smoke-token-report.ts"
    # A source with NO declared test resolving: must still fire (the control).
    command printf '%s\n' "export function orphaned() {}" >"$sb/scripts/lonely.ts"

    command printf '%s\n' \
        "$sb/scripts/token-report.ts" \
        "$sb/scripts/smoke-token-report.ts" \
        "$sb/scripts/lonely.ts" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$GATE_OUT"
    # Leading `/` anchors on the path separator: "token-report.ts" is a
    # SUBSTRING of "smoke-token-report.ts", so an unanchored assertion here
    # passes or fails on the wrong row (see the isolation cases below).
    assert_not_contains "$rows" "/token-report.ts	1	missing-test-file" \
        "test_discovery template resolves the source to its declared test"
    assert_not_contains "$rows" "smoke-token-report.ts" \
        "test_patterns marks the smoke file itself as a test, not a source"
    assert_contains "$rows" "lonely.ts" \
        "a source with no resolving declared test still fires (control)"
}

# The two keys must each work ALONE. Declared together (the case above), a bug
# that made either one a no-op would be masked by the other: test_patterns
# silences the smoke file, and test_discovery silences the source, so either
# alone still produces "fewer rows". These two cases isolate them.
test_test_patterns_works_without_discovery() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' \
        "test_patterns:" \
        "  - 'scripts/smoke-*.ts'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' "export function buildReport() {}" >"$sb/scripts/token-report.ts"
    command printf '%s\n' "import x from './token-report';" >"$sb/scripts/smoke-token-report.ts"
    command printf '%s\n' \
        "$sb/scripts/token-report.ts" "$sb/scripts/smoke-token-report.ts" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_not_contains "$rows" "smoke-token-report.ts" \
        "test_patterns ALONE marks the smoke file as a test"
    # Without test_discovery nothing tells the scanner this smoke file covers
    # token-report.ts, so the source must STILL fire — proving test_patterns is
    # doing its own distinct job and not standing in for discovery.
    # Leading `/` again: without it this POSITIVE assertion would be satisfied
    # by the smoke-token-report.ts row and pass vacuously.
    assert_contains "$rows" "/token-report.ts	1	missing-test-file" \
        "test_patterns alone does NOT resolve a source to its test — that is test_discovery's job"
}

test_test_discovery_works_without_patterns() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' \
        "test_discovery:" \
        "  - 'scripts/smoke-{name}.ts'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' "export function buildReport() {}" >"$sb/scripts/token-report.ts"
    command printf '%s\n' "import x from './token-report';" >"$sb/scripts/smoke-token-report.ts"
    command printf '%s\n' \
        "$sb/scripts/token-report.ts" "$sb/scripts/smoke-token-report.ts" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    # NOTE the leading `/`: "token-report.ts" is a SUBSTRING of
    # "smoke-token-report.ts", which this same case expects to fire, so a bare
    # negative assertion would match the wrong row and fail for the wrong
    # reason. Anchor on the path separator to name the source file exactly.
    assert_not_contains "$rows" "/token-report.ts	1	missing-test-file" \
        "test_discovery ALONE resolves the source to its declared test"
    # Without test_patterns the smoke file is still scanned AS a source, and it
    # has no test of its own — so it must fire.
    assert_contains "$rows" "smoke-token-report.ts" \
        "test_discovery alone does NOT classify the smoke file as a test — that is test_patterns' job"
}

# --- #680: stdout_is_output — a CLI whose print() IS its output -------------

# `scan_debug_statements` flags any line-start print/console.log as HIGH. For a
# CLI that is the OUTPUT MECHANISM, and before #680 there was no way to say so:
# a repo of stdlib-only Python CLIs reported the same 313 rows forever, could
# never enable PRE_REVIEW_STRICT, and — the real cost — a genuinely stray
# `print(x)` was indistinguishable from the 104 legitimate ones beside it.
#
# The exemption is scoped to the PRINT family only. The debugger assertions
# below are the load-bearing half of every case here: the obvious
# implementation (an early return at the top of scan_debug_statements) silences
# breakpoints too, and would pass a fixture that only checked the print row was
# gone.
test_stdout_is_output_exempts_prints() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' \
        "stdout_is_output:" \
        "  - 'scripts/*.py'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' \
        'print("=== migration report ===")' \
        'breakpoint()' \
        'import pdb' >"$sb/scripts/migrate.py"
    command printf '%s\n' "$sb/scripts/migrate.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_contains "$rows" "Debug print statement" \
        "a declared CLI's print() is NOT flagged — it is the program's output"
    # AC3, asserted per-arm: both breakpoint idioms must survive the exemption.
    assert_contains "$rows" "Debugger statement: breakpoint()" \
        "breakpoint() STILL fires in a declared CLI file — never a program's output"
    assert_contains "$rows" "Debugger statement: import pdb" \
        "import pdb STILL fires in a declared CLI file"
}

# The JS mirror. Worth its own case rather than more files in the one above:
# the two families sit in DIFFERENT language arms of the split regions, so a
# per-language mistake (moving the `debugger` keyword into the print region)
# shows up here and nowhere else.
test_stdout_is_output_js_mirror() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/bin"
    command printf '%s\n' \
        "stdout_is_output:" \
        "  - 'bin/**'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' \
        'console.log("usage: tool [options]");' \
        'debugger;' >"$sb/bin/cli.js"
    command printf '%s\n' "$sb/bin/cli.js" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_contains "$rows" "Console debug statement" \
        "a declared CLI's console.log is NOT flagged"
    assert_contains "$rows" "Debugger keyword: debugger;" \
        "the debugger keyword STILL fires in a declared CLI file"
}

# The Go / Java arms, which have a print idiom but NO breakpoint idiom — so
# they exist only in the print region. Worth asserting through the real
# config-driven path: the sync gate's arm-shape check proves those arms are
# PRESENT in the exemptible region, not that matches_declared_stdout_pattern
# actually suppresses them. A per-language routing mistake would pass both the
# py and js cases above.
test_stdout_is_output_go_and_java() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/cmd"
    command printf '%s\n' \
        "stdout_is_output:" \
        "  - 'cmd/**'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' 'fmt.Println("usage: tool [options]")' >"$sb/cmd/main.go"
    command printf '%s\n' 'System.out.println("usage");' >"$sb/cmd/Main.java"
    # Undeclared siblings: the controls proving the suppression is path-scoped
    # and not "the go/java arms stopped firing".
    command mkdir -p "$sb/internal"
    command printf '%s\n' 'fmt.Println("left in by accident")' >"$sb/internal/svc.go"
    command printf '%s\n' 'System.out.println("left in by accident");' >"$sb/internal/Svc.java"
    command printf '%s\n' \
        "$sb/cmd/main.go" "$sb/cmd/Main.java" \
        "$sb/internal/svc.go" "$sb/internal/Svc.java" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_contains "$rows" "/main.go" \
        "a declared CLI's fmt.Println is NOT flagged"
    assert_not_contains "$rows" "/Main.java" \
        "a declared CLI's System.out.println is NOT flagged"
    # One control per language: a routing bug that darkened ALL .go (or all
    # .java) regardless of declaration is a different failure from a
    # path-scoping bug, and only a same-language control catches it.
    assert_contains "$rows" "/svc.go" \
        "an undeclared .go still fires — the go arm did not simply go silent"
    assert_contains "$rows" "/Svc.java" \
        "an undeclared .java still fires — the java arm did not simply go silent"
}

# Every mktemp -d repo the gate creates must be reclaimed by the EXIT trap.
#
# BEHAVIOURAL, not structural: the gate runs with TMPDIR pointed at an empty
# directory and the leftovers are counted afterwards. A grep for the variable
# name in cleanup_skip_policy would pass on a branch that named the right
# variable and removed the wrong path.
#
# The declaration below exercises ALL THREE repos in one run (skip-policy is
# unconditional; test_patterns and stdout_is_output each need their key
# present), so this covers the existing two as well as the new one — the leak
# it was written for was a third repo added without a matching cleanup branch,
# and the next key would repeat it.
test_declared_pattern_repos_are_cleaned_up() {
    local sb tmp leftovers
    new_git_sandbox sb
    tmp="$(command mktemp -d "$WORKDIR/tmphome.XXXXXX")"

    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' \
        "test_patterns:" \
        "  - 'scripts/smoke-*.py'" \
        "stdout_is_output:" \
        "  - 'scripts/cli.py'" >"$sb/.claude/pre-review.yml"
    command printf '%s\n' 'print("report")' >"$sb/scripts/cli.py"
    command printf '%s\n' "$sb/scripts/cli.py" >"$sb/files.txt"

    GATE_RC=0
    GATE_OUT="$(cd "$sb" &&
        TMPDIR="$tmp" /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$GATE" "$sb/files.txt" 2>/dev/null)" || GATE_RC=$?

    assert_exit 0 "$GATE_RC" "the gate run itself succeeded (leak check is meaningful)"

    # Every entry here is a temp dir the gate created and failed to reclaim.
    leftovers="$(command find "$tmp" -mindepth 1 -maxdepth 1 | command wc -l | command tr -d '[:space:]')"
    assert_equals "0" "$leftovers" \
        "the EXIT trap reclaims every temp repo — no mktemp -d is left behind"
}

# The control: the key exempts what it NAMES, not the language. Without this a
# blanket "exempt every .py" bug would pass every assertion above.
test_stdout_is_output_undeclared_file_still_fires() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/scripts" "$sb/src"
    command printf '%s\n' \
        "stdout_is_output:" \
        "  - 'scripts/*.py'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' 'print("report")' >"$sb/scripts/cli.py"
    command printf '%s\n' 'print("left in by accident")' >"$sb/src/service.py"
    command printf '%s\n' "$sb/scripts/cli.py" "$sb/src/service.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "/service.py" \
        "an UNDECLARED file's print() still fires — the key is not a global off-switch"
    assert_not_contains "$rows" "/cli.py" \
        "...while the declared file beside it stays exempt"
}

# With no pre-review.yml the new lookup must be inert. Sibling of
# test_no_config_means_no_declared_behavior, which guards the #568 keys the
# same way: an empty pattern list that matched everything would silence the
# whole category while the scan still exited 0.
test_stdout_is_output_inert_without_config() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/scripts"
    command printf '%s\n' 'print("report")' 'breakpoint()' >"$sb/scripts/cli.py"
    command printf '%s\n' "$sb/scripts/cli.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "Debug print statement" \
        "with no config, print() is flagged exactly as before #680"
    assert_contains "$rows" "Debugger statement" \
        "with no config, breakpoint() is flagged exactly as before #680"
}

# stdout_is_output must be its OWN claim, not an alias for the other two keys.
# This is the assertion behind the issue's rejected alternatives: reusing
# test_skip_patterns would silence missing-test-file as a side effect, and
# sharing test_patterns' check-ignore repo would mark the CLI a TEST. Both
# mistakes are invisible in the debug-statement category — they only surface
# here, in the categories that must NOT have changed.
test_stdout_is_output_does_not_leak_into_test_categories() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/scripts"
    command printf '%s\n' \
        "stdout_is_output:" \
        "  - 'scripts/*.py'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' \
        'def build_report():' \
        '    print("report")' >"$sb/scripts/cli.py"
    command printf '%s\n' "$sb/scripts/cli.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_contains "$rows" "/cli.py" \
        "stdout_is_output does NOT suppress missing-test-file — that is test_skip_patterns' claim"
}

# A source basename carrying whitespace and glob metacharacters must not break
# the find OR-chain that js_test_find_args builds, nor abort the scan. The
# scanner runs under `set -euo pipefail` over arbitrary repo paths, so a crash
# here would take down the whole pre-scan rather than one file.
#
# `[` is a genuine `find -name` metacharacter, so such a source is NOT expected
# to MATCH its test — the assertion is that the run survives and still reports,
# which is the correct degradation.
test_hostile_basename_does_not_break_scan() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "export const x = 1;" >"$sb/src/my report[1].ts"
    command printf '%s\n' "covers it" >"$sb/tests/validate-plain.mjs"
    command printf '%s\n' "$sb/src/my report[1].ts" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_exit 0 "$GATE_RC" \
        "a basename with whitespace and glob chars does not abort the scan"
    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_contains "$rows" "my report[1].ts" \
        "and the file is still reported rather than silently dropped"
}

# Absent any config the declared-convention code must be inert — no repo
# without a pre-review.yml may change behaviour. Guards against the new
# lookups accidentally matching (e.g. an empty pattern list matching all).
test_no_config_means_no_declared_behavior() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/scripts"
    command printf '%s\n' "export function buildReport() {}" >"$sb/scripts/token-report.ts"
    command printf '%s\n' "import x from './token-report';" \
        >"$sb/scripts/smoke-token-report.ts"
    command printf '%s\n' \
        "$sb/scripts/token-report.ts" "$sb/scripts/smoke-token-report.ts" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_contains "$rows" "token-report.ts" \
        "with no config, the smoke- convention is NOT inferred — source still fires"
    assert_contains "$rows" "smoke-token-report.ts" \
        "with no config, a smoke- file is treated as source, not a test"
}

# --- #568: .mjs/.cjs are source extensions ----------------------------------

# .mjs/.cjs used to fall through to the `*)` arm and emit a MEDIUM "Unknown
# file type" row. They are ordinary js sources and must route through the js/ts
# arm: HIGH missing-test-file when untested, silent when a test resolves.
test_mjs_recognized_as_source() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "export const x = 1;" >"$sb/src/tooling.mjs"
    command printf '%s\n' "export const y = 1;" >"$sb/src/covered.cjs"
    command printf '%s\n' "// covers covered.cjs" >"$sb/tests/validate-covered.mjs"
    command printf '%s\n' "$sb/src/tooling.mjs" "$sb/src/covered.cjs" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "missing-test-file")"
    assert_contains "$rows" "tooling.mjs	1	missing-test-file	No test file found" \
        "an untested .mjs is a HIGH missing-test-file, not a MEDIUM unknown type"
    assert_not_contains "$rows" "Unknown file type" \
        "no unknown-file-type row for a .mjs/.cjs source"
    assert_not_contains "$rows" "covered.cjs" \
        "a .cjs source with a repo-rooted test is silent"
}

# Routing .mjs/.cjs into the js/ts arms must be CONSISTENT across categories.
# Cycle 1's correctness dimension caught the asymmetry this pins: the first cut
# added mjs|cjs to scan_missing_tests and scan_untested_public_api but left
# scan_debug_statements matching only *.js|*.ts|*.jsx|*.tsx — so a console.log
# in a .mjs was silent while the identical line in a .js was HIGH. A file
# treated as first-class JS by two categories and invisible to a third is the
# silent-false-negative shape this scanner exists to avoid.
#
# The debug arm lives in the `>>> shared:debug-statement-scan` region, so the
# fix spans pre-review-gates.sh, check-code-health/patterns.sh AND patterns.py.
test_mjs_debug_statement_parity() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "console.log('left in by accident');" >"$d/tool.mjs"
    command printf '%s\n' "console.log('left in by accident');" >"$d/tool.cjs"
    command printf '%s\n' "console.log('left in by accident');" >"$d/tool.js"

    run_gate "$(make_list "$d" tool.mjs tool.cjs tool.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_contains "$rows" "tool.js" "control: a .js console.log is flagged"
    assert_contains "$rows" "tool.mjs" \
        "a .mjs console.log is flagged too — same treatment as .js (#568)"
    assert_contains "$rows" "tool.cjs" \
        "a .cjs console.log is flagged too — same treatment as .js (#568)"
}

# --- #568: cross-directory untested-public-api ------------------------------

# scan_untested_public_api probed only two COLOCATED paths, so an export
# genuinely exercised from a repo-rooted tests/ tree reported HIGH "no tests
# reference". It now searches the same candidate set scan_missing_tests uses.
#
# The control export in the SAME file is the important half: the fallback must
# find the symbol, not merely find the file.
test_cross_directory_untested_public_api() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' \
        "export function referenced() {}" \
        "export function neverMentioned() {}" >"$sb/src/api.ts"
    command printf '%s\n' \
        "import {referenced} from '../src/api';" \
        "referenced();" >"$sb/tests/validate-api-helpers.mjs"
    command printf '%s\n' "$sb/src/api.ts" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "referenced:" \
        "an export referenced from a repo-rooted test emits no finding (#568)"
    assert_contains "$rows" "neverMentioned" \
        "an unreferenced export in the same file still fires — the symbol is checked, not just the file"
}
