# shellcheck shell=bash
# okf-migrate — bash <-> python parity.
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# WHY PARITY LIVES HERE rather than in tests/validate-python-ports.sh: that
# gate's contract is FILE-LIST shaped (argv[1] is a list of paths; no args ->
# exit 1 + Usage; empty list -> exit 0 silent), and its scope rule says plainly
# that a port with a different CLI shape must be pinned by its own suite instead
# of being bent to fit. A mode-shaped CLI is exactly that case — the same call
# split-verify.{py,sh} made and records.
#
# WHAT PARITY DOES NOT PROVE (#684): a defect present in BOTH impls passes,
# because this compares them to each other and never to what the transform was
# meant to do. That is why the correctness assertions live in fragments 20-50
# and this one only asserts agreement — the two kinds of check are not
# substitutes.
#
# The APPLIED-TREE case is the one that matters most: check and plan agreement
# is agreement about a REPORT, while tree agreement is agreement about what the
# tool actually did to someone's files.

parity_bundle() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "alpha.md" '---
type: reference
---

See [[beta]] and [[missing-one|the missing one]].'
    write_concept "$root" "beta.md" '---
name: beta
metadata:
  type: project
---

Body.'
    write_concept "$root" "feedback/lesson.md" '---
name: lesson
---

Lesson body.'
    # A file needing TWO transforms at once — an insert near the top and a
    # replace further down. This is the shape that caught a real divergence: the
    # two runtimes agreed on every REPORT while the bash writer applied the
    # edits in the wrong order and corrupted the body. Keeping it in the parity
    # bundle means the applied-tree case guards the ordering too.
    write_concept "$root" "multi.md" '---
name: multi
metadata:
  type: project
---

line one
See [[beta]] here.
line three'
    command printf '%s' "$root"
}

test_parity_check_mode() {
    local root py sh
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — parity needs both runtimes"
        return
    fi
    root="$(parity_bundle)"
    run_py check "$root"
    py="$OKF_OUT"
    run_sh check "$root"
    sh="$OKF_OUT"
    assert_equals "$py" "$sh" "bash and python agree byte-for-byte in check mode"
    assert_not_empty "$py" "the comparison ran against real output, not two empty strings"
}

test_parity_plan_mode() {
    local root py sh
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — parity needs both runtimes"
        return
    fi
    root="$(parity_bundle)"
    run_py plan "$root"
    py="$OKF_OUT"
    run_sh plan "$root"
    sh="$OKF_OUT"
    assert_equals "$py" "$sh" "bash and python agree byte-for-byte in plan mode"
    assert_contains "$py" "@@ " "the compared output actually contained hunks (vacuity guard)"
}

test_parity_applied_tree() {
    local py_root sh_root py_digest sh_digest
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — parity needs both runtimes"
        return
    fi
    py_root="$(parity_bundle)"
    sh_root="$(parity_bundle)"

    run_py apply "$py_root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the python apply succeeded"
    run_sh apply "$sh_root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the bash apply succeeded"

    py_digest="$(tree_digest "$py_root")"
    sh_digest="$(tree_digest "$sh_root")"

    # THE STRONGEST PARITY CLAIM in this suite: the two runtimes did the same
    # thing to the files, not merely said the same thing about them. A report
    # can agree while the writers diverge — a wrong line number, a shifted
    # insert, a differently-escaped body — and only this case would catch it.
    assert_equals "$py_digest" "$sh_digest" \
        "bash and python produce byte-identical applied trees"
    assert_contains "$py_digest" "okf_version" \
        "the compared trees actually contain a migration (vacuity guard)"
}

test_parity_refusal_exit_codes() {
    local root py_rc sh_rc
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — parity needs both runtimes"
        return
    fi

    # Missing --confirm -> 2 in both.
    root="$(parity_bundle)"
    run_py apply "$root"
    py_rc="$OKF_RC"
    run_sh apply "$root"
    sh_rc="$OKF_RC"
    assert_equals "2" "$py_rc" "python refuses a bare apply with 2"
    assert_equals "$py_rc" "$sh_rc" "bash agrees on the missing-confirm code"

    # A plan-only transform -> 2 in both.
    run_py apply "$root" --transform split-index --confirm --allow-dirty
    py_rc="$OKF_RC"
    run_sh apply "$root" --transform split-index --confirm --allow-dirty
    sh_rc="$OKF_RC"
    assert_equals "2" "$py_rc" "python refuses a plan-only transform with 2"
    assert_equals "$py_rc" "$sh_rc" "bash agrees on the plan-only code"

    # An ambiguity -> 3 in both. A DIFFERENT code from the refusals above, and
    # the impls must agree on which is which: a caller branches on these, so a
    # divergence would route one runtime's "needs a human" into the other's
    # "you have something to do".
    local amb
    amb="$(fresh_bundle "$WORKDIR")"
    write_concept "$amb" "unmatched.md" '---
name: unmatched
---

Body.'
    run_py apply "$amb" --transform backfill-type --confirm --allow-dirty
    py_rc="$OKF_RC"
    run_sh apply "$amb" --transform backfill-type --confirm --allow-dirty
    sh_rc="$OKF_RC"
    assert_equals "3" "$py_rc" "python reports an ambiguity as 3, distinct from a refusal"
    assert_equals "$py_rc" "$sh_rc" "bash agrees on the ambiguity code"
}

test_parity_path_containing_a_tab() {
    local root tabbed py_root
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — parity needs both runtimes"
        return
    fi
    # A FILENAME CONTAINING A TAB. The edit record is tab-delimited, so an
    # unescaped path splits the record and every later field shifts. Measured:
    # python migrated `feedback/odd<TAB>name.md` and bash SILENTLY DID NOT —
    # the grep that re-selects a target's rows could never match a path whose
    # own tab had become a delimiter, so the file was listed in the plan with no
    # hunks under it and then skipped at apply. A silent skip, not an error.
    #
    # Fixing it needed TWO changes, and the second is the non-obvious one:
    # escaping the path field, AND matching encoded fields with `grep -F` —
    # plain grep reads the escaped `\t` in the PATTERN as a regex escape and
    # fails to match the literal two characters in the file.
    root="$(fresh_bundle "$WORKDIR")"
    py_root="$(fresh_bundle "$WORKDIR")"
    for tabbed in "$root" "$py_root"; do
        write_concept "$tabbed" "t.md" '---
type: reference
---

T.'
        command mkdir -p "$tabbed/feedback"
        command printf -- '---\nname: odd\n---\n\nSee [[t]].\n' \
            >"$tabbed/feedback/odd	name.md"
    done

    run_sh apply "$root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "a bundle with a tab-bearing filename applies in bash"
    run_py apply "$py_root" --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "and in python"

    assert_equals "$(tree_digest "$py_root")" "$(tree_digest "$root")" \
        "both runtimes migrate a tab-bearing path identically"
    assert_contains "$(command cat "$root/feedback/odd	name.md")" "type: feedback" \
        "the tab-bearing file was actually migrated, not silently skipped"
}
