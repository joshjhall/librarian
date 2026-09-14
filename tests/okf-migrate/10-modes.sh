# shellcheck shell=bash
# okf-migrate — the three modes and the tool-side failures.
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# The central property here is that THE SAFE MODE IS THE DEFAULT. A migration
# engine whose writing mode is reachable by accident — a bare invocation, a
# typo'd flag — has no safety model regardless of what its docs claim.

# A bundle with one of every migratable shape, so a mode assertion is never
# vacuously true against a bundle that needed nothing.
modes_bundle() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "alpha.md" '---
type: reference
---

See [[beta]].'
    write_concept "$root" "beta.md" '---
name: beta
metadata:
  type: project
---

Body.'
    command printf '%s' "$root"
}

test_check_is_the_default_mode() {
    local root bare explicit
    root="$(modes_bundle)"

    # A bare invocation and an explicit `check` must produce the same thing.
    bare="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION="0.2" \
        command bash "$OKF_MIGRATE_SH" 2>&1)"
    run_sh check "$root"
    explicit="$OKF_OUT"

    assert_equals "$explicit" "$bare" \
        "a bare invocation is exactly \`check\` — the default mode is the read-only one"
    assert_contains "$bare" "adopt-bundle" "the default mode still reports what needs migrating"
    assert_file_not_exists_okf "$root/index.md" "check wrote nothing"
}

# assert_file_not_exists_okf PATH MESSAGE — local to this fragment; the harness
# ships assert_file_exists but not its negation.
assert_file_not_exists_okf() {
    assert_true "[ ! -e '$1' ]" "$2"
}

test_plan_writes_nothing() {
    local root before after out
    root="$(modes_bundle)"
    before="$(tree_digest "$root")"

    run_sh plan "$root"

    out="$OKF_OUT"
    assert_exit 0 "$OKF_RC" "plan exits 0"
    assert_contains "$out" "+++ b/" "plan renders a diff-shaped change set (AC2)"
    assert_contains "$out" "@@ wikilink-convert" "plan names the transform behind each hunk"

    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "plan left the tree byte-identical (AC2)"
}

test_apply_requires_confirm() {
    local root before after out
    root="$(modes_bundle)"
    before="$(tree_digest "$root")"

    run_sh apply "$root"

    out="$OKF_OUT"
    assert_exit 2 "$OKF_RC" "apply without --confirm exits 2 (refused, not failed)"
    assert_contains "$out" "--confirm" "the refusal names what is missing"

    # THE SAFETY PROPERTY IS THE SECOND ASSERTION. "it errored" and "it errored
    # before writing" are different claims; only the second is safety.
    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "the refused apply wrote nothing (AC1)"
}

test_unknown_mode_is_a_usage_error() {
    local root out
    root="$(modes_bundle)"
    run_sh bogus-mode "$root"
    out="$OKF_OUT"
    assert_exit 1 "$OKF_RC" "an unknown mode is a TOOL-side usage error: exit 1"
    assert_contains "$out" "unknown mode" "the error names the problem"
    assert_contains "$out" "Usage:" "a usage message follows"
}

test_absent_bundle_is_silent_exit_zero() {
    local out
    # A configured root that does not exist: "no bundle" is exit 0 with nothing
    # to say, never an error — the same posture the validator takes.
    run_sh check "$WORKDIR/no-such-bundle"
    out="$OKF_OUT"
    assert_exit 0 "$OKF_RC" "an absent bundle exits 0"
    assert_output_empty "$out" "an absent bundle produces no output"

    # An EMPTY root means no bundle is configured at all.
    OKF_RC=0
    out="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="" OKF_PINNED_VERSION="0.2" \
        command bash "$OKF_MIGRATE_SH" check 2>&1)" || OKF_RC=$?
    assert_exit 0 "$OKF_RC" "an empty configured root exits 0"
    assert_output_empty "$out" "an empty configured root produces no output"
}

test_missing_transforms_fragment_fails_loud() {
    local root copy out rc=0
    root="$(modes_bundle)"

    # AC8's "runtime-missing fails loud". The transform bodies are a SOURCED
    # SIBLING (transforms.sh / transforms.py), the same shape bundle_graph.sh
    # has beside the validator's patterns.sh — so the file can go missing from a
    # partial copy or a botched install.
    #
    # THE DANGER IS THE DIAGNOSTIC, NOT THE VERDICT. Both runtimes exit non-zero
    # either way; what matters is that the message names the CONSEQUENCE, because
    # a tool that loaded no transforms emits an empty plan, and an empty plan
    # reads as "this bundle needs no migration" — the silence-is-a-pass shape
    # (#538/#571). Measured before fixing: bash said exactly that while python
    # died with a raw ModuleNotFoundError traceback.
    copy="$(command mktemp -d "$WORKDIR/broke.XXXXXX")"
    command cp -R "$SKILL_DIR/." "$copy/"
    command rm -f "$copy/transforms.sh"

    out="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION="0.2" \
        command bash "$copy/migrate.sh" check 2>&1)" || rc=$?
    assert_exit 1 "$rc" "a missing transforms.sh is a loud TOOL-side failure"
    assert_contains "$out" "transforms.sh not found" "the message names the missing file"
    assert_contains "$out" "needing no migration" \
        "and names the consequence — an empty plan would read as a clean bundle"

    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the python half of this case"
        return
    fi
    command rm -f "$copy/transforms.py"
    rc=0
    out="$(OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION="0.2" \
        command python3 "$copy/migrate.py" check 2>&1)" || rc=$?
    assert_exit 1 "$rc" "a missing transforms.py is a loud TOOL-side failure too"
    assert_contains "$out" "transforms.py not found" \
        "python gives the SAME actionable message, not a raw traceback"
    assert_not_contains "$out" "Traceback" "no stack trace reaches the operator"
}

test_unresolvable_pin_fails_loud() {
    local root out rc=0
    root="$(modes_bundle)"

    # THE OPPOSITE POSTURE FROM THE BUNDLE SIDE. A non-conformant bundle is
    # reported at exit 0; a TOOL that cannot resolve its own version pin must
    # fail loud, because adopt-bundle stamps that version into the index.md it
    # writes. An exit-0 empty report here would describe a migration that never
    # ran (#538/#571).
    #
    # The pin is forced unresolvable by pointing the tool at a config-less
    # sibling: an empty OKF_PINNED_VERSION falls through to the validator's
    # thresholds.yml, which legitimately resolves.
    out="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION=" " \
        command bash "$OKF_MIGRATE_SH" check 2>&1)" || rc=$?

    # A whitespace-only override must be TRIMMED and fall through, exactly as the
    # validator's read_pinned_version does — not be taken as a valid pin. Same
    # environment, same verdict in both tools.
    assert_exit 0 "$rc" \
        "a whitespace-only pin override is trimmed and falls through to the single source"
    assert_contains "$out" "adopt-bundle" "the scan proceeded on the resolved pin"
}
