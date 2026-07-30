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

# --- Scanner self-scan suppression (#599) -----------------------------------

# The detectors' patterns are regex literals inside their own grep/re.search
# calls, so scanning a diff that touches a scanner file made every literal match
# ITSELF — HIGH-certainty rows for a guaranteed non-problem, on exactly the PRs
# where reviewer attention is worth most.
#
# The fix is LINE-scoped, and this case pins BOTH halves of that from a SINGLE
# fixture, which is the whole point: the suppressed pattern-source line and a
# genuine hedging comment live in the same file. A path-based exemption (the
# rejected option 2) would silence both and still pass a test that only checked
# the first half — so asserting the negative alone would be a green light on the
# wrong implementation.
test_ai_slop_skips_scanner_pattern_literals() {
    local d rows
    d="$(fresh_dir)"
    {
        command printf '%s\n' "#!/usr/bin/env bash"
        command printf '%s\n' "# It's worth noting that this parser is fragile."
        command printf '%s\n' "scan() {"
        command printf '%s\n' "    command grep -niE -- '\\b(it.s worth noting that|importantly,)\\b' \"\$1\""
        command printf '%s\n' "}"
    } >"$d/scanner.sh"
    run_gate "$(make_list "$d" scanner.sh)"

    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    # The grep-invocation line (4) is pattern SOURCE — must not be flagged.
    assert_not_contains "$rows" "	4	" \
        "a scanner pattern-literal invocation emits no ai-slop row (#599 AC#1)"
    # ...while the prose comment (2) in the SAME file still fires. This is the
    # anti-blanket-exemption assertion (#599 AC#2).
    assert_contains "$rows" "	2	" \
        "a genuine hedging comment in a scanner file still fires (#599 AC#2)"
}

# The same shape for debug-statement, whose patterns self-match too (#599).
#
# The reachable form here is NOT the bash `command grep -nE ...` invocation the
# ai-slop case uses: the debug arms are anchored `^\s*console\.` / `^\s*print\(`,
# so an indented grep line never matched them and a fixture built that way would
# assert nothing — it passes with or without the fix. The line that genuinely
# self-matches is one that EMITS a pattern literal, i.e. a `console.log(` /
# `print(` at line start whose argument is the regex. Verified to fire on the
# pre-fix scanner before being pinned here.
test_debug_statement_skips_scanner_pattern_literals() {
    local d rows
    d="$(fresh_dir)"
    {
        command printf '%s\n' "console.log(\"grep -nE -- '^\\\\s*console\\\\.(log)\\\\('\");"
        command printf '%s\n' "console.log('genuine debug left behind');"
    } >"$d/scan.js"
    run_gate "$(make_list "$d" scan.js)"

    rows="$(category_rows "$GATE_OUT" "debug-statement")"
    assert_not_contains "$rows" "	1	" \
        "a line emitting a scanner pattern literal emits no debug-statement row (#599)"
    assert_contains "$rows" "	2	" \
        "a genuine console.log in the same file still fires (#599)"
}

# ai-slop never called is_test_file, unlike debug-statement which always has
# (#599). A corpus fixture GENERATES slop on purpose — the heredoc and `printf`
# lines that build a detector's input are not unedited AI output. Measured over
# the #567 batch these fixture-generator lines were the majority of surviving
# ai-slop rows.
test_ai_slop_skips_test_files() {
    local d rows control
    d="$(fresh_dir)"
    command mkdir -p "$d/tests"
    command printf '%s\n' "# It's worth noting that this fixture is deliberate." >"$d/tests/fixture.py"
    command printf '%s\n' "# It's worth noting that this is unedited output." >"$d/src.py"
    run_gate "$(make_list "$d" tests/fixture.py src.py)"

    rows="$(category_rows "$GATE_OUT" "ai-slop")"
    assert_not_contains "$rows" "fixture.py" \
        "a hedging phrase under tests/ emits no ai-slop row (#599)"
    # Control: the same phrase in real source still fires, so the suppression is
    # scoped to test paths rather than having disabled the detector outright.
    control="$(command printf '%s\n' "$rows" | command grep -c 'src\.py' || true)"
    assert_equals "1" "$control" \
        "...while the same phrase in a non-test source still fires (#599)"
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

# --- #598: shell is a scanned source language -------------------------------

# The headline #598 case. `*.sh` sat in test-skip-patterns.default, so shell
# files never reached scan_missing_tests — in a repo whose test suites ARE shell
# that silenced the scanner on the bulk of every diff, and an empty pre-scan is
# indistinguishable in the handoff from a clean one.
#
# An untested .sh must fire; one covered by tests/validate-<name>.sh must not.
# Both assertions live in ONE run so a pass cannot come from the scanner having
# gone globally silent.
test_sh_missing_test_fires_and_convention_silences() {
    local sb list tested control
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests"
    command printf '%s\n' "echo covered" >"$sb/scripts/covered.sh"
    command printf '%s\n' "# exercises covered.sh" >"$sb/tests/validate-covered.sh"
    command printf '%s\n' "echo lonely" >"$sb/scripts/lonely.sh"

    list="$sb/files.txt"
    command printf '%s\n' "$sb/scripts/covered.sh" "$sb/scripts/lonely.sh" >"$list"

    run_gate_in "$sb" "$list"

    tested="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'covered\.sh' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.sh' || true)"

    assert_equals "0" "$tested" \
        "a .sh covered by tests/validate-<name>.sh emits no missing-test-file (#598 AC#2)"
    assert_equals "1" "$control" \
        "an untested .sh emits missing-test-file (#598 AC#1)"
}

# EVERY alternative sh_test_find_args builds, so a typo isolated to any single
# entry has a test that fails. Sampling one exemplar per stem would leave the
# wildcard forms unexercised — the trap #555's stem-form case documents.
#
# Each row runs in its own sandbox holding exactly ONE test file, so a match can
# only come from the alternative under test.
#
# Every row carries an UNTESTED control alongside the subject. Without it these
# rows assert only an ABSENCE and pass vacuously whenever the scanner is silent
# for an unrelated reason — verified: with `*.sh` restored to the skip list this
# case still passed until the control was added.
test_sh_stem_forms_all_match() {
    local sb stem form fname ext i=0
    local stems="validate-thing test-thing test_thing thing_test thing.test thing-test"

    for stem in $stems; do
        for form in exact hyphen underscore; do
            # Alternate the extension so both .sh and .bash are covered.
            if [ $((i % 2)) -eq 0 ]; then ext="sh"; else ext="bash"; fi
            i=$((i + 1))
            case "$form" in
                exact) fname="${stem}.${ext}" ;;
                hyphen) fname="${stem}-extra.${ext}" ;;
                underscore) fname="${stem}_extra.${ext}" ;;
            esac

            new_git_sandbox sb
            command mkdir -p "$sb/scripts" "$sb/tests"
            command printf '%s\n' "echo thing" >"$sb/scripts/thing.sh"
            command printf '%s\n' "# test" >"$sb/tests/$fname"
            command printf '%s\n' "echo lonely" >"$sb/scripts/lonely.sh"
            command printf '%s\n' \
                "$sb/scripts/thing.sh" "$sb/scripts/lonely.sh" >"$sb/files.txt"

            run_gate_in "$sb" "$sb/files.txt"

            assert_equals "0" \
                "$(category_rows "$GATE_OUT" "missing-test-file" |
                    command grep -c 'thing\.sh' || true)" \
                "tests/$fname suppresses missing-test-file for thing.sh (#598)"
            assert_equals "1" \
                "$(category_rows "$GATE_OUT" "missing-test-file" |
                    command grep -c 'lonely\.sh' || true)" \
                "...and the untested control still fires alongside tests/$fname (#598)"
        done
    done
}

# The non-stem arms: an exact same-name suite (tests/<name>.sh) and the
# split-suite fragment layout (#564), where cases live at tests/<suite>/NN-<area>.sh.
# Same control discipline as the stem-form case above.
test_sh_exact_and_fragment_arms_match() {
    local sb fname
    for fname in "gate-watch.sh" "suite/20-gate-watch.sh" "suite/20-gate-watch-extra.sh"; do
        new_git_sandbox sb
        command mkdir -p "$sb/scripts" "$sb/tests/suite"
        command printf '%s\n' "echo x" >"$sb/scripts/gate-watch.sh"
        command printf '%s\n' "# test" >"$sb/tests/$fname"
        command printf '%s\n' "echo lonely" >"$sb/scripts/lonely.sh"
        command printf '%s\n' \
            "$sb/scripts/gate-watch.sh" "$sb/scripts/lonely.sh" >"$sb/files.txt"

        run_gate_in "$sb" "$sb/files.txt"

        assert_equals "0" \
            "$(category_rows "$GATE_OUT" "missing-test-file" |
                command grep -c 'gate-watch\.sh' || true)" \
            "tests/$fname suppresses missing-test-file for gate-watch.sh (#598)"
        assert_equals "1" \
            "$(category_rows "$GATE_OUT" "missing-test-file" |
                command grep -c 'lonely\.sh' || true)" \
            "...and the untested control still fires alongside tests/$fname (#598)"
    done
}

# The hyphen-stripped candidate (golem-status -> status) is what lets a
# tests/golem-scripts/60-status.sh count for scripts/golem-status.sh.
#
# It is EXACT-ONLY, and the negative half is the point: allowing wildcard forms
# on the stripped token was measured to match bin/ruff-version.sh against
# tests/release/10-version-utils.sh via a bare `version` — a silent false
# negative on a file with no test of its own. If that arm is ever loosened, the
# second assertion here fails.
test_sh_stripped_candidate_is_exact_only() {
    local sb hit miss
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests/golem-scripts" "$sb/tests/release"
    command printf '%s\n' "echo s" >"$sb/scripts/golem-status.sh"
    command printf '%s\n' "# test" >"$sb/tests/golem-scripts/60-status.sh"
    # No test named after ruff-version; only a WILDCARD-form file on the bare
    # stripped token `version`, which must NOT count.
    command printf '%s\n' "echo r" >"$sb/scripts/ruff-version.sh"
    command printf '%s\n' "# test" >"$sb/tests/release/10-version-utils.sh"

    command printf '%s\n' \
        "$sb/scripts/golem-status.sh" "$sb/scripts/ruff-version.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    hit="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'golem-status\.sh' || true)"
    miss="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'ruff-version\.sh' || true)"

    assert_equals "0" "$hit" \
        "the stripped candidate matches an EXACT NN-<cand>.sh fragment (#598)"
    assert_equals "1" "$miss" \
        "the stripped candidate does NOT match a wildcard form — no false negative (#598)"
}

# The strip removes ONE leading segment, not all of them: `golem-gate-watch`
# becomes `gate-watch`, not `watch`. Only the single-hyphen case was covered
# above, so the multi-hyphen behaviour — which segment actually goes, and
# whether the remaining multi-word candidate still reaches the exact-only arms —
# was unexercised.
#
# The sandbox holds ONLY the stripped-form fragment, so a match can come from
# nothing else, and a `watch`-only file is present as a negative: if the strip
# ever became greedy (`${name##*-}`) the first assertion would still pass on
# that file, so the second pins the direction.
test_sh_stripped_candidate_strips_one_segment() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests/suite"
    command printf '%s\n' "echo x" >"$sb/scripts/golem-gate-watch.sh"
    command printf '%s\n' "# test" >"$sb/tests/suite/20-gate-watch.sh"
    # Greedy-strip bait: matches `watch`, which a one-segment strip never yields.
    command printf '%s\n' "echo y" >"$sb/scripts/golem-token-scrape.sh"
    command printf '%s\n' "# test" >"$sb/tests/suite/30-scrape.sh"
    command printf '%s\n' \
        "$sb/scripts/golem-gate-watch.sh" "$sb/scripts/golem-token-scrape.sh" \
        >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'golem-gate-watch\.sh' || true)" \
        "a multi-hyphen name strips ONE segment: golem-gate-watch -> gate-watch (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'golem-token-scrape\.sh' || true)" \
        "...and does NOT strip to the last segment — 30-scrape.sh must not match (#598)"
}

# A `.bash` SOURCE file end-to-end. The `sh | bash)` case label claims .bash is
# handled, and both the colocated list and the repo-rooted globs carry .bash
# arms — but every other case here scans a `.sh` source and varies .bash only on
# the discovered TEST file. A regression breaking .bash-source handling outright
# would have gone unnoticed, so this scans the .bash source itself, through both
# the colocated path and the repo-rooted path, with an untested control.
test_bash_source_is_scanned() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests"
    # colocated .bash test for a .bash source
    command printf '%s\n' "echo c" >"$sb/scripts/colo.bash"
    command printf '%s\n' "# test" >"$sb/scripts/test_colo.bash"
    # repo-rooted test for a .bash source
    command printf '%s\n' "echo r" >"$sb/scripts/rooted.bash"
    command printf '%s\n' "# test" >"$sb/tests/validate-rooted.sh"
    # untested control
    command printf '%s\n' "echo l" >"$sb/scripts/lonely.bash"

    command printf '%s\n' \
        "$sb/scripts/colo.bash" "$sb/scripts/rooted.bash" "$sb/scripts/lonely.bash" \
        >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'colo\.bash' || true)" \
        "a .bash source with a colocated test_<name>.bash is silent (#598)"
    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'rooted\.bash' || true)" \
        "a .bash source with a repo-rooted tests/validate-<name>.sh is silent (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'lonely\.bash' || true)" \
        "an untested .bash source still emits missing-test-file (#598)"
}

# The colocated list accepts the hyphen `test-<name>` form, not just the
# underscore one — the repo-rooted stem set has always accepted both, and the
# two discovery paths must agree on what a test is named.
test_sh_colocated_hyphen_form_matches() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/scripts/tests"
    command printf '%s\n' "echo a" >"$sb/scripts/alpha.sh"
    command printf '%s\n' "# test" >"$sb/scripts/test-alpha.sh"
    command printf '%s\n' "echo b" >"$sb/scripts/beta.sh"
    command printf '%s\n' "# test" >"$sb/scripts/tests/test-beta.sh"
    command printf '%s\n' "echo l" >"$sb/scripts/lonely.sh"
    command printf '%s\n' \
        "$sb/scripts/alpha.sh" "$sb/scripts/beta.sh" "$sb/scripts/lonely.sh" \
        >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'alpha\.sh' || true)" \
        "a colocated sibling test-<name>.sh suppresses missing-test-file (#598)"
    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'beta\.sh' || true)" \
        "a colocated tests/test-<name>.sh suppresses missing-test-file (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'lonely\.sh' || true)" \
        "...while the untested control still fires (#598)"
}

# A DIRECTORY named like a test must not suppress a finding — the `-type f`
# guard carried over from find_repo_rooted_js_tests. Without it a snapshot or
# fixture dir silently hides exactly the bug this scanner reports.
test_sh_probe_ignores_directories() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests/validate-thing.sh"
    command printf '%s\n' "echo thing" >"$sb/scripts/thing.sh"
    command printf '%s\n' "$sb/scripts/thing.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'thing\.sh' || true)" \
        "a DIRECTORY named tests/validate-thing.sh does not suppress the finding (#598)"
}

# tests/fixtures/** is excluded. This repo keeps scanner fixtures at
# tests/fixtures/category-parity/match/patterns.sh; without the exclusion every
# plugins/**/patterns.sh matched that one file and 14 real scanners went
# silently "covered". A fixture is an input to a test, not a test.
test_sh_probe_excludes_fixtures() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/skills" "$sb/tests/fixtures/parity/match"
    command printf '%s\n' "echo p" >"$sb/skills/patterns.sh"
    command printf '%s\n' "# fixture, not a test" \
        >"$sb/tests/fixtures/parity/match/patterns.sh"
    command printf '%s\n' "$sb/skills/patterns.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'patterns\.sh' || true)" \
        "a same-named file under tests/fixtures/ does not count as a test (#598)"
}

# The probe stays name-anchored: an unrelated shell test in the tree must not
# satisfy a source it says nothing about.
test_sh_probe_is_name_anchored() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts" "$sb/tests"
    command printf '%s\n' "echo orphan" >"$sb/scripts/orphan.sh"
    command printf '%s\n' "# unrelated" >"$sb/tests/validate-something-else.sh"
    command printf '%s\n' "$sb/scripts/orphan.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'orphan\.sh' || true)" \
        "an unrelated tests/*.sh does not suppress missing-test-file (#598)"
}

# Two boundaries of the skip-list edit, in one run.
#
# *.zsh STAYS skipped: it has no discovery arm, so un-skipping it would route
# zsh to the unknown-extension MEDIUM branch — noise, not a finding. And a .sh
# must NOT produce untested-public-api: shell has no export syntax and #598
# explicitly defers that to its own design. Un-skipping *.sh routes shell into
# scan_untested_public_api for the first time, so this pins that it stays a
# no-op there rather than silently gaining a half-designed category.
test_sh_skip_and_category_boundaries() {
    local sb
    new_git_sandbox sb

    command mkdir -p "$sb/scripts"
    command printf '%s\n' "echo z" >"$sb/scripts/thing.zsh"
    command printf '%s\n' "run() { echo hi; }" "run" >"$sb/scripts/exports.sh"
    command printf '%s\n' "$sb/scripts/thing.zsh" "$sb/scripts/exports.sh" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    assert_equals "0" \
        "$(command printf '%s\n' "$GATE_OUT" | command grep -c 'thing\.zsh' || true)" \
        "*.zsh is still skipped — no unknown-extension MEDIUM row (#598)"
    assert_equals "0" \
        "$(category_rows "$GATE_OUT" "untested-public-api" |
            command grep -c 'exports\.sh' || true)" \
        "a .sh emits no untested-public-api — shell has no arm there (#598)"
    assert_equals "1" \
        "$(category_rows "$GATE_OUT" "missing-test-file" |
            command grep -c 'exports\.sh' || true)" \
        "...while the same .sh still emits missing-test-file (not globally silent)"
}

# This repo's OWN tree: the naming convention resolves for real files, so the
# fix cannot be passing only on synthetic sandboxes. Uses sources whose tests
# reach them through three DIFFERENT arms.
test_real_repo_sh_sources_not_flagged() {
    local d list rows control
    d="$(fresh_dir)"
    list="$d/files.txt"
    # An untested control OUTSIDE the repo accompanies the three real sources,
    # so a pass cannot come from the scanner being silent for shell generally.
    command printf '%s\n' "echo lonely" >"$d/lonely.sh"
    # validate-<name>.sh | exact same-name suite | NN-<stripped> fragment
    command printf '%s\n' \
        "$REPO_ROOT/plugins/workflow/hooks/bash-guard.sh" \
        "$REPO_ROOT/plugins/workflow/scripts/golem-gate-watch.sh" \
        "$REPO_ROOT/plugins/workflow/scripts/golem-status.sh" \
        "$d/lonely.sh" >"$list"

    run_gate "$list"

    rows="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -cE 'bash-guard\.sh|golem-gate-watch\.sh|golem-status\.sh' || true)"
    control="$(category_rows "$GATE_OUT" "missing-test-file" |
        command grep -c 'lonely\.sh' || true)"

    assert_equals "0" "$rows" \
        "real repo shell sources covered by the convention emit no missing-test-file (#598 AC#3)"
    assert_equals "1" "$control" \
        "...while an untested control in the same run still fires (#598)"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_ai_slop_fires "ai-slop detector fires on a hedging phrase with a 5-column HIGH row"
run_test test_debug_statement_fires "debug-statement detector fires on a top-level console.log"
run_test test_ai_slop_skips_scanner_pattern_literals "ai-slop skips a scanner's own pattern literal, but not prose in the same file (#599)"
run_test test_debug_statement_skips_scanner_pattern_literals "debug-statement skips a scanner's own pattern literal, but not a real console.log (#599)"
run_test test_ai_slop_skips_test_files "ai-slop skips test files (fixture generators), control in real source still fires (#599)"
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
run_test test_mjs_debug_statement_parity "a .mjs/.cjs console.log is flagged like a .js one — no silent category gap (#568)"
run_test test_cross_directory_untested_public_api "untested-public-api sees a repo-rooted test, and still checks the SYMBOL (#568)"
run_test test_untested_public_api_fires "untested-public-api detector fires and names the function"
run_test test_clean_source_silent "a clean, tested, private-only source emits no findings"
run_test test_skip_policy_override_honored "project pre-review.yml override suppresses a skipped path, not a control"
run_test test_sh_missing_test_fires_and_convention_silences "an untested .sh fires; tests/validate-<name>.sh silences it (#598 AC#1/AC#2)"
run_test test_sh_stem_forms_all_match "all 6 stems x 3 forms x both extensions match (#598)"
run_test test_sh_exact_and_fragment_arms_match "exact same-name and NN-<name> split-suite fragment arms match (#598)"
run_test test_sh_stripped_candidate_is_exact_only "the hyphen-stripped candidate is exact-only — no wildcard false negative (#598)"
run_test test_sh_stripped_candidate_strips_one_segment "the stripped candidate removes ONE segment, not all (#598)"
run_test test_bash_source_is_scanned "a .bash SOURCE routes through the sh|bash arm, colocated and repo-rooted (#598)"
run_test test_sh_colocated_hyphen_form_matches "the colocated list accepts the hyphen test-<name> form (#598)"
run_test test_sh_probe_ignores_directories "a directory named like a shell test does not suppress the finding (#598)"
run_test test_sh_probe_excludes_fixtures "a same-named file under tests/fixtures/ is not a test (#598)"
run_test test_sh_probe_is_name_anchored "the shell probe stays name-anchored (#598)"
run_test test_sh_skip_and_category_boundaries "*.zsh still skipped; .sh emits no untested-public-api but does emit missing-test-file (#598)"
run_test test_real_repo_sh_sources_not_flagged "this repo's own convention-covered shell sources are not flagged (#598 AC#3)"

generate_report
