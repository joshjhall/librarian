# shellcheck shell=bash
# Selectivity (clean source stays silent) + project skip-policy override
#
# Area fragment of tests/validate-pre-review-gates.sh (#895). Sourced, not
# executed. Shared drivers live in tests/lib/pre-review-gates-sandbox.sh.

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
