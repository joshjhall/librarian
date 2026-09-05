# shellcheck shell=bash
# Category: untested-public-api — py/go cross-directory, module public-symbol selection
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

# --- Category: untested-public-api ------------------------------------------

# A public def with no referencing test_*.py must produce an untested-public-api
# row naming the function.
#
# Runs in a git SANDBOX, not a bare fresh_dir: once the py arm searches the
# repo-rooted tests/ tree for the symbol (#600), a fixture named in a bare temp
# dir is judged against the OUTER librarian checkout's tests/ — and the string
# `public_thing` appears in THIS file, so the case suppressed its own fixture
# and the detector looked broken. The sandbox pins _PROJECT_ROOT locally, which
# is what the #568/#598 cross-directory cases already do for the same reason.
test_untested_public_api_fires() {
    local sb rows
    new_git_sandbox sb

    command printf '%s\n' "def public_thing(a):" "    return a" >"$sb/api.py"
    command printf '%s\n' "$sb/api.py" >"$sb/files.txt"
    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_empty "$rows" "untested public def must emit an untested-public-api row"
    assert_contains "$rows" "public_thing" "row names the untested function"
}

# --- untested-public-api: py/go cross-directory (#600) ----------------------

# AC#1 + AC#2. A py public function referenced only from a repo-rooted tests/
# tree must emit no row, while a genuinely unreferenced def IN THE SAME FILE
# still fires — the #568 control shape, proving the SYMBOL is checked and not
# merely the file's existence.
test_py_cross_directory_untested_public_api() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' \
        "def referenced_fn(a):" "    return a" \
        "def never_mentioned_fn(b):" "    return b" >"$sb/src/api.py"
    # Deliberately NOT named after the source: the py candidate set is
    # symbol-anchored, so a differently-named suite must still count.
    command printf '%s\n' \
        "from src.api import referenced_fn" \
        "def test_it():" "    assert referenced_fn(1) == 1" >"$sb/tests/validate-things.sh"
    command printf '%s\n' "$sb/src/api.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "referenced_fn:" \
        "a py def referenced from a repo-rooted test emits no finding (#600 AC#1)"
    assert_contains "$rows" "never_mentioned_fn" \
        "an unreferenced def in the same file still fires — the symbol is checked (#600 AC#2)"
}

# The */fixtures/* exclusion is a real filter. A fixture is an INPUT to a test,
# not a test for the symbol it happens to name (#598's rationale). Without this
# the scanner buys a lower row count with silent false negatives.
test_py_symbol_probe_excludes_fixtures() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests/fixtures"
    command printf '%s\n' "def fixture_only_fn(a):" "    return a" >"$sb/src/api.py"
    command printf '%s\n' "fixture_only_fn is named here but this is a fixture" \
        >"$sb/tests/fixtures/sample.py"
    command printf '%s\n' "$sb/src/api.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "fixture_only_fn" \
        "a symbol named only under tests/fixtures/ is not covered (#600)"
}

# The *.md exclusion. Documentation that mentions a symbol does not exercise it
# — tests/ARCHITECTURE.md names `main`, and counting that as coverage would be a
# false negative bought with prose.
test_py_symbol_probe_excludes_markdown() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' "def documented_only_fn(a):" "    return a" >"$sb/src/api.py"
    command printf '%s\n' "# Notes" "documented_only_fn is described here." \
        >"$sb/tests/NOTES.md"
    command printf '%s\n' "$sb/src/api.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "documented_only_fn" \
        "a symbol named only in a tests/*.md doc is not covered (#600)"
}

# Regression: the colocated probes the cross-directory fallback was added
# BEHIND must keep working. A test_<name>.py beside the source still suppresses.
test_py_colocated_test_still_detected() {
    local sb rows
    new_git_sandbox sb

    command printf '%s\n' "def colocated_fn(a):" "    return a" >"$sb/api.py"
    command printf '%s\n' "from api import colocated_fn" \
        "def test_it():" "    assert colocated_fn(1) == 1" >"$sb/test_api.py"
    command printf '%s\n' "$sb/api.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "colocated_fn" \
        "a colocated test_<name>.py still suppresses the finding (#600 regression)"
}

# symbol_in_candidate_list's docstring justifies iterating one path at a time
# (rather than handing the whole list to a single `grep -l`) so a path containing
# a SPACE is not word-split. That is a falsifiable claim about the code, so it
# gets a test: a candidate under a space-bearing directory, with a space-bearing
# filename, must still suppress the finding.
test_py_candidate_path_with_spaces() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests/dir with spaces"
    command printf '%s\n' \
        "def spaced_fn(a):" "    return a" \
        "def other_fn(b):" "    return b" >"$sb/src/api.py"
    command printf '%s\n' \
        "from src.api import spaced_fn" \
        "spaced_fn(1)" >"$sb/tests/dir with spaces/check me.py"
    command printf '%s\n' "$sb/src/api.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "spaced_fn" \
        "a candidate whose path contains spaces is still grepped, not word-split (#600)"
    assert_contains "$rows" "other_fn" \
        "the control in the same file still fires (#600)"
}

# The declared-convention join reaches the py arm too. #568 gave the js/ts arm a
# `declared_test_paths` join into the same candidate list; #600 added it to py
# and go, but every pre-existing test_discovery case uses .ts fixtures, so the
# new join had no direct coverage. A declared template pointing OUTSIDE the
# repo-rooted tests/ tree isolates it: nothing else can resolve that path, so the
# assertion can only pass via the declared join.
#
# The two fixture symbols are deliberately NOT prefix-related. A first draft used
# declared_fn / undeclared_fn, and the negative assertion failed against its own
# control: "declared_fn:" is a SUBSTRING of "undeclared_fn:", so the row proving
# correct behavior also matched the string asserted absent. Same class as the
# leading-`/` anchoring note in test_declared_test_conventions_honored.
test_py_declared_discovery_join() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/src" "$sb/smoke"
    command printf '%s\n' \
        "test_discovery:" \
        "  - 'smoke/check_{name}.py'" >"$sb/.claude/pre-review.yml"
    command printf '%s\n' \
        "def template_fn(a):" "    return a" \
        "def plain_fn(b):" "    return b" >"$sb/src/api.py"
    command printf '%s\n' \
        "from src.api import template_fn" \
        "template_fn(1)" >"$sb/smoke/check_api.py"
    command printf '%s\n' "$sb/src/api.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "template_fn:" \
        "a py symbol referenced from a DECLARED test_discovery path emits no finding (#600)"
    assert_contains "$rows" "plain_fn" \
        "an unreferenced def in the same file still fires — the declared join is not a blanket skip (#600)"
}

# --- untested-public-api: module public-symbol selection (#606) -------------
#
# #600 fixed test DISCOVERY; these cover symbol SELECTION. Every case below puts
# the ARMING fixture and the SATISFYING fixture in SEPARATE files: a single
# module that both triggers the gate and satisfies it would pass whether or not
# the gate exists, which is the tautology that made an earlier assertion in this
# file prove nothing (see the note above test_go_stays_silent_without_any_candidate).

# AC#1 + AC#2 in one run. A helper in a main()-guarded CLI module is not public
# API — it is driven THROUGH the entry point, so no test is expected to name it.
# The control lives in a separate, UNGUARDED module and must still fire, which
# is what proves the gate is selective rather than globally silencing.
test_py_main_guarded_helper_not_public_api() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        "def guarded_helper(a):" "    return a" \
        "def main(argv):" "    return guarded_helper(argv)" \
        'if __name__ == "__main__":' "    raise SystemExit(main(None))" >"$sb/src/cli.py"
    command printf '%s\n' \
        "def library_export(a):" "    return a" >"$sb/src/lib.py"
    command printf '%s\n' "$sb/src/cli.py" "$sb/src/lib.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "guarded_helper" \
        "a helper in a main()-guarded CLI module is not public API (#606 AC#1)"
    assert_contains "$rows" "library_export" \
        "a genuinely public, genuinely untested def in a plain module still fires (#606 AC#2)"
}

# The main() guard must be the MODULE's entry point. A guard indented inside a
# function or class is not one, so it must not silence the whole file — without
# the column-0 anchor this fixture goes quiet and the gate over-suppresses.
test_py_nested_main_guard_does_not_gate_module() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        "def outer(a):" \
        '    if __name__ == "__main__":' \
        "        pass" \
        "    return a" >"$sb/src/nested.py"
    command printf '%s\n' "$sb/src/nested.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "outer" \
        "an INDENTED __main__ guard is not a module entry point and does not gate it (#606)"
}

# __all__ wins over the guard, in BOTH directions — a listed name stays public
# even in a guarded module, an unlisted one does not. Both assertions in one run
# so neither can pass by the scanner having gone silent.
test_py_dunder_all_overrides_main_guard() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        '__all__ = ["declared_api"]' \
        "def declared_api(a):" "    return a" \
        "def undeclared_helper(b):" "    return b" \
        'if __name__ == "__main__":' "    pass" >"$sb/src/dual.py"
    command printf '%s\n' "$sb/src/dual.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "declared_api" \
        "a name in __all__ stays public even in a main()-guarded module (#606)"
    assert_not_contains "$rows" "undeclared_helper" \
        "a def absent from __all__ is not public API (#606)"
}

# A single-line `__all__ = ["x"]` must terminate on its OWN closing bracket. A
# `sed -n '/start/,/end/p'` range does not (it looks for the end pattern from the
# NEXT line), so it ran on to the next `]`/`)` in the file and swallowed
# unrelated quoted strings as exported names. Here `phantom_helper` is quoted in
# a string constant below __all__: if it leaks into the name list it becomes
# "public" and fires a row that must not exist.
test_py_single_line_dunder_all_does_not_overrun() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        '__all__ = ["real_api"]' \
        'MSG = ("phantom_helper",)' \
        "def real_api(a):" "    return a" \
        "def phantom_helper(b):" "    return b" \
        'if __name__ == "__main__":' "    pass" >"$sb/src/oneline.py"
    command printf '%s\n' "$sb/src/oneline.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "real_api" \
        "the single-line __all__ name is parsed (#606)"
    assert_not_contains "$rows" "phantom_helper" \
        "a quoted string AFTER a single-line __all__ is not an exported name (#606)"
}

# A multi-line __all__ collects every listed name across its continuation lines,
# and still excludes what it omits.
test_py_multiline_dunder_all_collects_all_names() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        "__all__ = [" '    "alpha",' '    "beta",' "]" \
        "def alpha(a):" "    return a" \
        "def beta(b):" "    return b" \
        "def gamma(c):" "    return c" >"$sb/src/multi.py"
    command printf '%s\n' "$sb/src/multi.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "alpha" "the first multi-line __all__ name is public (#606)"
    assert_contains "$rows" "beta" "a LATER multi-line __all__ name is public too (#606)"
    assert_not_contains "$rows" "gamma" \
        "a def absent from a multi-line __all__ is not public API (#606)"
}

# An ANNOTATED declaration — `__all__: list[str] = [...]` — is valid, ruff-clean
# Python. A gate matching only `__all__ =` misses it, so a guarded module's real
# API resolves to "none" and its genuinely-untested exports are silently
# swallowed. That is the over-suppression direction: a false NEGATIVE, which is
# the failure mode this whole category exists to avoid.
test_py_annotated_dunder_all_recognized() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        '__all__: list[str] = ["annotated_api"]' \
        "def annotated_api(a):" "    return a" \
        "def annotated_helper(b):" "    return b" \
        'if __name__ == "__main__":' "    pass" >"$sb/src/annot.py"
    command printf '%s\n' "$sb/src/annot.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "annotated_api" \
        "an ANNOTATED __all__ is recognized, so its listed name stays public (#606)"
    assert_not_contains "$rows" "annotated_helper" \
        "an annotated __all__ still excludes what it omits (#606)"
}

# The __all__ membership test is whole-word: a name that is a strict PREFIX of a
# listed one must not inherit its public status. Unpadded substring matching
# would let `check_mcp` pass on the strength of `check_mcp_config`.
test_py_dunder_all_membership_is_whole_word() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        '__all__ = ["check_mcp_config"]' \
        "def check_mcp_config(a):" "    return a" \
        "def check_mcp(b):" "    return b" \
        'if __name__ == "__main__":' "    pass" >"$sb/src/prefix.py"
    command printf '%s\n' "$sb/src/prefix.py" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "check_mcp_config" \
        "the listed name itself is public (#606)"
    assert_not_contains "$rows" "No tests reference check_mcp:" \
        "a strict PREFIX of a listed name is not public by substring accident (#606)"
}

# The go arm is deliberately untouched by #606 — capitalization already IS go's
# visibility rule and there is no main()-guard analog. A go file carrying the
# python guard text verbatim must behave exactly as before.
test_go_arm_unaffected_by_py_symbol_gate() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' \
        "package main" \
        'if __name__ == "__main__":' \
        "func ExportedThing(a int) int {" "    return a" "}" >"$sb/src/app.go"
    command printf '%s\n' "package main" "func TestOther(t *testing.T) {}" \
        >"$sb/tests/other_test.go"
    command printf '%s\n' "$sb/src/app.go" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "ExportedThing" \
        "the go arm still fires — the py symbol gate does not leak across arms (#606)"
}

# AC#3 — the headline number. This repo's own patterns.py files are all
# main()-guarded CLI scripts whose helpers are exercised through the entry point
# by tests/coverage-python.sh; #600 took them 49 rows -> 16, and this takes the
# residual 16 -> 0. Runs against the REAL tree, so it cannot pass on a fixture.
test_real_repo_patterns_py_emit_no_untested_public_api() {
    local list rows
    list="$(command mktemp)"
    command find "$REPO_ROOT/plugins" -name 'patterns.py' -print >"$list"

    run_gate_in "$REPO_ROOT" "$list"
    command rm -f "$list"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_equals "" "$rows" \
        "this repo's patterns.py files emit zero untested-public-api rows (#606 AC#3 / #600 AC#3)"
}

# AC#4 — the go arm is covered, not deferred. An exported func referenced from a
# repo-rooted test emits nothing; an unreferenced one in the same file fires.
test_go_cross_directory_untested_public_api() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src" "$sb/tests"
    command printf '%s\n' \
        "package src" \
        "func ReferencedFn(a int) int { return a }" \
        "func NeverMentionedFn(b int) int { return b }" >"$sb/src/api.go"
    command printf '%s\n' \
        "package tests" \
        "func TestIt(t *testing.T) { ReferencedFn(1) }" >"$sb/tests/api_test.go"
    command printf '%s\n' "$sb/src/api.go" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "ReferencedFn:" \
        "a go export referenced from a repo-rooted test emits no finding (#600 AC#4)"
    assert_contains "$rows" "NeverMentionedFn" \
        "an unreferenced go export in the same file still fires (#600 AC#4)"
}

# The go contract's REAL failure mode, and the one the first cut of #600 got
# wrong: a POPULATED tests/ tree that has nothing to do with this go package.
#
# The arm's gate is "at least one candidate test exists". When the repo-rooted
# candidate list was unrestricted (every non-fixture, non-.md file under tests/),
# that gate was permanently true in any repo with a tests/ tree — including this
# one — so an untested go package emitted one HIGH row per exported func, the
# exact noise the conservative contract exists to prevent.
#
# test_go_stays_silent_without_any_candidate below CANNOT catch this: it creates
# no tests/ dir at all, so the fallback never engages. This case is the one that
# fails against the unrestricted list.
test_go_unrelated_tests_tree_does_not_arm_the_gate() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/pkg" "$sb/tests"
    command printf '%s\n' \
        "package pkg" \
        "func Alpha(a int) int { return a }" >"$sb/pkg/api.go"
    # Populated tests/ tree with NO go test in it.
    command printf '%s\n' "unrelated shell suite" >"$sb/tests/validate-other.sh"
    command printf '%s\n' "$sb/pkg/api.go" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_output_empty "$rows" \
        "a populated but go-less tests/ tree does not arm the go candidate gate (#600 regression)"
}

# The declared-convention join reaches the GO arm too — the py case above has a
# sibling here because the join was added to both arms and each resolves its
# candidate list separately.
test_go_declared_discovery_join() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/.claude" "$sb/pkg" "$sb/smoke"
    command printf '%s\n' \
        "test_discovery:" \
        "  - 'smoke/check_{name}.go'" >"$sb/.claude/pre-review.yml"
    command printf '%s\n' \
        "package pkg" \
        "func TemplateFn(a int) int { return a }" \
        "func PlainFn(b int) int { return b }" >"$sb/pkg/api.go"
    command printf '%s\n' \
        "package smoke" \
        "func TestIt(t *testing.T) { TemplateFn(1) }" >"$sb/smoke/check_api.go"
    command printf '%s\n' "$sb/pkg/api.go" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_not_contains "$rows" "TemplateFn" \
        "a go symbol referenced from a DECLARED test_discovery path emits no finding (#600)"
    assert_contains "$rows" "PlainFn" \
        "an unreferenced export in the same file still fires — the declared join is not a blanket skip (#600)"
}

# find_repo_rooted_go_tests carries the same */fixtures/* exclusion as the py
# helper: a *_test.go under tests/fixtures/ is an INPUT to a test, not coverage.
#
# The fixture must be the ONLY thing naming the symbol while something ELSE arms
# the candidate gate — here a real repo-rooted *_test.go that exercises a
# different export. A first draft omitted that second file and was a TAUTOLOGY:
# with the exclusion the gate was simply unarmed (no rows), and without it the
# fixture both armed the gate and satisfied the symbol (also no rows), so the
# assertion held either way and proved nothing. Caught by mutation-testing —
# deleting the exclusion left the case passing.
test_go_probe_excludes_fixtures() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/pkg" "$sb/tests/fixtures"
    command printf '%s\n' \
        "package pkg" \
        "func FixtureOnlyFn(a int) int { return a }" >"$sb/pkg/api.go"
    # Arms the gate, but says nothing about FixtureOnlyFn.
    command printf '%s\n' \
        "package tests" \
        "func TestSomethingElse(t *testing.T) { Unrelated(1) }" \
        >"$sb/tests/real_test.go"
    # The ONLY mention of the symbol — and it must not count.
    command printf '%s\n' \
        "package fixtures" \
        "func TestIt(t *testing.T) { FixtureOnlyFn(1) }" \
        >"$sb/tests/fixtures/sample_test.go"
    command printf '%s\n' "$sb/pkg/api.go" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_contains "$rows" "FixtureOnlyFn" \
        "a *_test.go under tests/fixtures/ does not count as coverage for the symbol it names (#600)"
}

# The go arm's CONSERVATIVE contract is preserved: with no candidate test file
# anywhere it stays silent and leaves the package to missing-test-file, rather
# than emitting one row per exported func. Widening WHICH candidates count must
# not make the arm fire where it was previously quiet.
test_go_stays_silent_without_any_candidate() {
    local sb rows
    new_git_sandbox sb

    command mkdir -p "$sb/src"
    command printf '%s\n' \
        "package src" \
        "func LonelyFn(a int) int { return a }" >"$sb/src/api.go"
    command printf '%s\n' "$sb/src/api.go" >"$sb/files.txt"

    run_gate_in "$sb" "$sb/files.txt"

    rows="$(category_rows "$GATE_OUT" "untested-public-api")"
    assert_output_empty "$rows" \
        "go emits no untested-public-api row when no candidate test exists at all (#600)"
}
