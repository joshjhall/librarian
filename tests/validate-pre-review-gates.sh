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

# Every stem form the repo-rooted probe claims to support, one per case, plus
# both wildcard suffixes and the REVERSE cross-extension direction (a .ts source
# found by a .js test — the headline case only proves .js found by .mjs).
#
# has_repo_rooted_js_test builds a 6-stem x 6-extension x 3-suffix find
# expression. Without this, five of the six stems and the `_*` suffix have no
# test at all: a typo in any one `find_args` entry silently reintroduces the
# HIGH false positives this issue exists to remove, and every other case here
# would still pass because they all happen to exercise `validate-<name>-*`.
#
# Each row runs in its own sandbox with exactly ONE test file present, so a
# match can only come from the stem under test.
test_repo_rooted_stem_forms_all_match() {
    local sb rows case_desc test_file source_name
    # "<test-file-to-create> <source-name> <what-it-covers>"
    while read -r test_file source_name case_desc; do
        [ -n "$test_file" ] || continue
        new_git_sandbox sb

        command mkdir -p "$sb/src" "$sb/tests"
        command printf '%s\n' "const x = 1;" >"$sb/src/${source_name}"
        command printf '%s\n' "// covers ${source_name}" >"$sb/tests/${test_file}"
        command printf '%s\n' "$sb/src/${source_name}" >"$sb/files.txt"

        run_gate_in "$sb" "$sb/files.txt"

        rows="$(category_rows "$GATE_OUT" "missing-test-file" || true)"
        assert_output_empty "$rows" \
            "tests/${test_file} covers ${source_name} (${case_desc})"
    done <<'CASES'
thing.test.ts thing.js <name>.test stem, .ts test for a .js source
thing.spec.js thing.js <name>.spec stem
test-thing.mjs thing.js test-<name> stem
test_thing.cjs thing.js test_<name> stem
spec-thing.jsx thing.js spec-<name> stem
validate-thing.tsx thing.js validate-<name> stem, exact form
validate-thing_extra.js thing.js the _* wildcard suffix
validate-comp-helpers.js comp.ts REVERSE cross-extension: .ts source, .js test
CASES
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

# #555 AC#3, asserted against THIS repo rather than a fixture: the real
# ship-issue workflow.js is covered by tests/validate-workflow-helpers.mjs and
# must emit no missing-test-file row.
#
# The second assertion pins the #555/#568 BOUNDARY. untested-public-api is
# explicitly out of scope for #555 (it is #568's third gap), so that row is
# still expected here. If #568 later silences it, this assertion is the
# reminder to update the boundary deliberately rather than by accident.
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
        "this repo's ship-issue/workflow.js emits no missing-test-file (AC#3)"
    assert_true "[ $api -ge 1 ]" \
        "untested-public-api still fires — that gap is #568's, not #555's"
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
run_test test_repo_rooted_stem_forms_all_match "every repo-rooted stem form + both wildcards + reverse cross-extension match (#555)"
run_test test_colocated_js_test_still_detected "colocated <name>.test.js still suppresses missing-test-file (#555 regression)"
run_test test_repo_rooted_probe_is_name_anchored "repo-rooted probe stays name-anchored — unrelated tests/ files don't count (#555)"
run_test test_real_repo_workflow_js_not_flagged "this repo's ship-issue/workflow.js: no missing-test-file, untested-public-api still fires (#555 AC#3)"
run_test test_untested_public_api_fires "untested-public-api detector fires and names the function"
run_test test_clean_source_silent "a clean, tested, private-only source emits no findings"
run_test test_skip_policy_override_honored "project pre-review.yml override suppresses a skipped path, not a control"

generate_report
