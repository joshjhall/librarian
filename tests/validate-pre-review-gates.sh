#!/usr/bin/env bash
# Negative-fixture coverage for the four scan categories AND the project
# skip-policy override in pre-review-gates.sh (issue #83).
#
# plugins/workflow/skills/ship-issue/pre-review-gates.sh is the
# deterministic pre-scan /ship-issue runs before PR creation. It emits
# TSV findings (file\tline\tcategory\tevidence\tcertainty) in four categories —
# ai-slop, debug-statement, missing-test-file, untested-public-api — and merges
# a project .claude/pre-review.yml into the bundled test-skip-patterns.default
# via load_test_skip_policy (lines 40-76), using `git check-ignore` to match.
#
# tests/validate-prescans.sh already pins the EMPTY-LIST / MISSING-ARG contract
# for every pre-scan; it does NOT prove any detector fires or that the
# skip-policy override is honored. A regression that silently muted a detector,
# or made the project YAML a no-op, would ship unnoticed. This gate is the
# additive negative-fixture half: it feeds each detector a fixture engineered to
# trip it and asserts the right category row appears with the right TSV shape,
# proves a clean file stays silent, and proves a project pre-review.yml override
# pattern actually suppresses a finding.
#
# The skip-policy case runs the REAL script inside a fresh `git init` sandbox
# with git's hook-exported environment scrubbed — pre-review-gates.sh resolves
# _PROJECT_ROOT via `git rev-parse --show-toplevel` to find .claude/pre-review.yml
# and the repo-rooted tests/ tree, so a leaked GIT_DIR under a `git push`
# pre-push hook would otherwise pin _PROJECT_ROOT to the OUTER librarian checkout
# (its real tests/ tree and absent pre-review.yml would corrupt the assertions).
# This mirrors tests/validate-golem-scripts.sh, the precedent for that scrub.
#
# Pure bash + coreutils + git, reached via absolute /usr/bin/* paths per project
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/plugins/workflow/skills/ship-issue/pre-review-gates.sh"

# Resolve the real bash once so child invocations work regardless of PATH.
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment — scrub per invocation so each run is hermetic
# even under a pre-push hook (see validate-golem-scripts.sh / golem-gate-watch).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "pre-review-gates scan categories + skip policy (#83)"

# Module-level scratch dir, cleaned up once when the suite exits.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# --- Helpers ----------------------------------------------------------------

# run_gate <file-list> — invoke the real gate with the git environment scrubbed,
# capturing stdout (the TSV findings). The file list holds one path per line.
# Exit code is captured in GATE_RC; the gate exits 0 on findings, so a non-zero
# here is a genuine failure worth surfacing.
GATE_RC=0
GATE_OUT=""
run_gate() {
    GATE_RC=0
    GATE_OUT="$(/usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "$REAL_BASH" "$GATE" "$1" 2>/dev/null)" || GATE_RC=$?
}

# category_rows <output> <category> — emit only the rows whose 3rd
# tab-separated column equals <category>. Filtering on column 3 implicitly
# asserts the file\tline\tcategory\t... layout, not a loose substring.
category_rows() {
    command printf '%s\n' "$1" |
        command awk -F '\t' -v cat="$2" '$3 == cat'
}

# field <row> <n> — the n-th tab-separated column of a single TSV row.
field() {
    command printf '%s\n' "$1" | command awk -F '\t' -v n="$2" '{print $n}'
}

# make_list <dir> <file...> — write a newline-delimited file list of the given
# paths (relative to <dir>) into <dir>/files.txt and echo its path.
make_list() {
    local dir="$1"
    shift
    local list="$dir/files.txt"
    : >"$list"
    local f
    for f in "$@"; do
        command printf '%s\n' "$dir/$f" >>"$list"
    done
    command printf '%s' "$list"
}

# fresh_dir — a unique per-case scratch dir under WORKDIR.
fresh_dir() {
    command mktemp -d "$WORKDIR/case.XXXXXX"
}

# new_git_sandbox <varname> — a fresh `git init` sandbox with one seed commit so
# HEAD exists and `git rev-parse --show-toplevel` resolves to the sandbox. All
# git calls run with the hook environment scrubbed so the sandbox is hermetic.
new_git_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.email "test@example.com"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" config user.name "Test"
    command printf 'seed\n' >"$dir/seed.txt"
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" add seed.txt 2>/dev/null
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" -c commit.gpgsign=false commit -qm seed 2>/dev/null || return 1
    printf -v "$__out" '%s' "$dir"
}

# run_gate_in <sandbox-dir> <file-list> — like run_gate, but cd'd into the
# sandbox first so _PROJECT_ROOT resolves to the sandbox (for the skip-policy
# case). File list is an absolute path.
run_gate_in() {
    local dir="$1" list="$2"
    GATE_RC=0
    GATE_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            "$REAL_BASH" "$GATE" "$list" 2>/dev/null)" || GATE_RC=$?
}

# --- Category: ai-slop ------------------------------------------------------

# A hedging phrase in a .py source must produce an ai-slop row. .py is chosen
# because test-skip-patterns scoping is irrelevant to ai-slop (it skips only
# data/doc extensions) and .py is unambiguously a scanned source type.
test_ai_slop_fires() {
    local d rows row
    d="$(fresh_dir)"
    command printf '%s\n' "# It's worth noting that this is unedited output." >"$d/slop.py"
    run_gate "$(make_list "$d" slop.py)"

    assert_exit 0 "$GATE_RC" "gate exits 0 while emitting findings"
    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    assert_not_empty "$rows" "ai-slop fixture must emit an ai-slop row"

    # First ai-slop row: 5 columns, file is slop.py, certainty HIGH.
    row="$(command printf '%s\n' "$rows" | command head -1)"
    assert_equals "5" "$(command printf '%s\n' "$row" | command awk -F '\t' '{print NF}')" \
        "ai-slop row must have 5 tab-separated columns"
    assert_contains "$(field "$row" 1)" "slop.py" "column 1 is the fixture path"
    assert_equals "HIGH" "$(field "$row" 5)" "hedging phrase is HIGH certainty"
}

# --- Category: debug-statement ----------------------------------------------

# A top-level console.log in a .js source must produce a debug-statement row.
test_debug_statement_fires() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "console.log('left in by accident');" >"$d/debug.js"
    run_gate "$(make_list "$d" debug.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_empty "$rows" "console.log fixture must emit a debug-statement row"
    assert_contains "$rows" "debug.js" "debug-statement row names the fixture"
}

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

# --- Category: untested-public-api ------------------------------------------

# A public def with no referencing test_*.py must produce an untested-public-api
# row naming the function.
test_untested_public_api_fires() {
    local d rows
    d="$(fresh_dir)"
    command printf '%s\n' "def public_thing(a):" "    return a" >"$d/api.py"
    run_gate "$(make_list "$d" api.py)"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_empty "$rows" "untested public def must emit an untested-public-api row"
    assert_contains "$rows" "public_thing" "row names the untested function"
}

# --- Selectivity: a clean, tested source stays silent -----------------------

# A .py source with a colocated test file, no public def, no slop, no debug must
# emit NOTHING — guards against a detector that fires unconditionally.
test_clean_source_silent() {
    local d
    d="$(fresh_dir)"
    command printf '%s\n' "_total = 0" >"$d/clean.py"
    command printf '%s\n' "def test_clean():" "    assert True" >"$d/test_clean.py"
    # Scan only clean.py (not the test file).
    run_gate "$(make_list "$d" clean.py)"

    assert_output_empty "$GATE_OUT" "a clean, tested, private-only source emits no findings"
}

# --- Skip policy: project .claude/pre-review.yml override -------------------

# load_test_skip_policy must merge a project pre-review.yml override. A pattern
# NOT in test-skip-patterns.default (generated/**) is placed in the project YAML;
# a source under generated/ must be suppressed while a control source outside it
# still fires missing-test-file — proving the override is parsed and applied
# (not just the bundled defaults, which never list generated/**).
test_skip_policy_override_honored() {
    local sb list skipped control
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/generated" "$sb/src"
    command printf '%s\n' \
        "test_skip_patterns:" \
        "  - 'generated/**'" >"$sb/.claude/pre-review.yml"

    command printf '%s\n' "value = 2" >"$sb/generated/gen_module.py"
    command printf '%s\n' "value = 3" >"$sb/src/real_module.py"

    # Absolute paths in the list (the gate scans absolute paths; _PROJECT_ROOT
    # strips the prefix to derive the relative path check-ignore matches).
    list="$sb/files.txt"
    command printf '%s\n' \
        "$sb/generated/gen_module.py" \
        "$sb/src/real_module.py" >"$list"

    run_gate_in "$sb" "$list"

    skipped="$(category_rows "$GATE_OUT" "missing-test-file" | command grep -c 'gen_module.py' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" | command grep -c 'real_module.py' || true)"

    assert_equals "0" "$skipped" \
        "generated/ source is suppressed by the project pre-review.yml override"
    assert_equals "1" "$control" \
        "control source outside the skip pattern still emits missing-test-file"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_ai_slop_fires "ai-slop detector fires on a hedging phrase with a 5-column HIGH row"
run_test test_debug_statement_fires "debug-statement detector fires on a top-level console.log"
run_test test_missing_test_file_fires "missing-test-file detector fires (line 1, HIGH) for an orphan source"
run_test test_repo_rooted_js_test_detected "repo-rooted tests/ + cross-extension test suppresses missing-test-file (#555)"
run_test test_repo_rooted_stem_forms_all_match "all 18 stem x suffix alternatives + every extension + reverse cross-extension match (#555)"
run_test test_repo_rooted_probe_rejects_foreign_extensions "the js/ts extension allowlist is a real filter — a same-stem .py does not match (#555)"
run_test test_repo_rooted_probe_ignores_directories "a directory named like a test does not suppress missing-test-file (#555)"
run_test test_colocated_js_test_still_detected "colocated <name>.test.js still suppresses missing-test-file (#555 regression)"
run_test test_repo_rooted_probe_is_name_anchored "repo-rooted probe stays name-anchored — unrelated tests/ files don't count (#555)"
run_test test_real_repo_workflow_js_not_flagged "this repo's ship-issue/workflow.js: no missing-test-file, untested-public-api still fires (#555 AC#3)"
run_test test_is_test_file_anchors_on_basename "is_test_file anchors name arms on the BASENAME — a test_-prefixed DIRECTORY does not skip source (#568)"
run_test test_declared_test_conventions_honored "declared test_patterns/test_discovery are honored, control still fires (#568)"
run_test test_test_patterns_works_without_discovery "test_patterns works ALONE and does not stand in for discovery (#568)"
run_test test_test_discovery_works_without_patterns "test_discovery works ALONE and does not classify the test file (#568)"
run_test test_hostile_basename_does_not_break_scan "a whitespace/glob-bearing basename degrades cleanly, no abort (#568)"
run_test test_no_config_means_no_declared_behavior "with no pre-review.yml the declared-convention path is inert (#568)"
run_test test_mjs_recognized_as_source ".mjs/.cjs route through the js/ts arm, not the unknown-type arm (#568)"
run_test test_cross_directory_untested_public_api "untested-public-api sees a repo-rooted test, and still checks the SYMBOL (#568)"
run_test test_untested_public_api_fires "untested-public-api detector fires and names the function"
run_test test_clean_source_silent "a clean, tested, private-only source emits no findings"
run_test test_skip_policy_override_honored "project pre-review.yml override suppresses a skipped path, not a control"

generate_report
