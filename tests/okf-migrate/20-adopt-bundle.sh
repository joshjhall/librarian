# shellcheck shell=bash
# okf-migrate — the adopt-bundle transform.
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# adopt-bundle turns a directory of memory files into a DECLARED OKF bundle by
# creating the bundle-root index.md that carries okf_version. The interesting
# properties are its idempotence (it never rewrites an operator's index) and its
# §8 scoping (root-level concepts only).

adopt_fixture() {
    local root
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "alpha.md" '---
type: reference
---

Alpha body.'
    write_concept "$root" "beta.md" '---
type: reference
---

Beta body.'
    command printf '%s' "$root"
}

test_adopt_creates_declared_index() {
    local root out
    root="$(adopt_fixture)"

    run_sh apply "$root" --transform adopt-bundle --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "adopt-bundle applies cleanly"

    assert_file_exists "$root/index.md" "adopt-bundle created the bundle-root index"
    out="$(command cat "$root/index.md")"
    assert_contains "$out" "okf_version: 0.2" \
        "the index declares the PINNED version, read from the toolset's single source"
    assert_contains "$out" "alpha.md" "the index names the bundle's concepts"
    assert_contains "$out" "beta.md" "the index names every root-level concept"
}

test_adopt_is_idempotent() {
    local root first second existing
    root="$(adopt_fixture)"

    run_sh apply "$root" --transform adopt-bundle --confirm --allow-dirty
    first="$(tree_digest "$root")"
    run_sh apply "$root" --transform adopt-bundle --confirm --allow-dirty
    second="$(tree_digest "$root")"
    assert_equals "$first" "$second" "applying adopt-bundle twice equals applying once (AC4)"

    # AND THE STRONGER CLAIM: an index the operator has edited is never
    # regenerated. A transform that rebuilt it would silently discard
    # hand-written index lines on every run — idempotent on its OWN output, but
    # destructive on a real one.
    command printf '%s\n' "- [hand-written](alpha.md) — an operator's own line" >>"$root/index.md"
    existing="$(command cat "$root/index.md")"
    run_sh apply "$root" --transform adopt-bundle --confirm --allow-dirty
    assert_equals "$existing" "$(command cat "$root/index.md")" \
        "an existing index.md is never rewritten — the operator's lines survive"
}

test_adopt_indexes_root_level_only() {
    local root out
    root="$(adopt_fixture)"
    write_concept "$root" "nested/deep.md" '---
type: reference
---

Nested body.'

    run_sh apply "$root" --transform adopt-bundle --confirm --allow-dirty
    out="$(command cat "$root/index.md")"

    # OKF §8 gives each DIRECTORY its own index.md, so a concept in `nested/` is
    # routed by `nested/index.md` — never by the root index. Naming it here
    # claims a routing relationship §8 does not define, AND the validator's
    # health pass (root-level only, by the same reasoning) reports every such
    # line as memory-dangling-index. Measured: the first implementation did
    # exactly this and produced a dangling row immediately after a clean apply.
    assert_not_contains "$out" "deep.md" \
        "a nested concept is NOT named by the root index (§8 — it has its own)"
    assert_contains "$out" "alpha.md" "root-level concepts are still indexed"
}

test_adopt_reversibility() {
    local root rows
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the validator drives the reversibility check"
        return
    fi
    root="$(adopt_fixture)"
    run_sh apply "$root" --transform adopt-bundle --confirm --allow-dirty

    validator_rows "$root"
    rows="$OKF_ROWS"

    # THE VACUITY GUARD. patterns.py takes a FILE LIST, not a directory — handed
    # a directory it scans nothing and exits 0, so "zero rows" would be true of a
    # check that never happened. Assert the list was non-empty FIRST.
    assert_true "[ '$OKF_LISTED' -gt 0 ]" \
        "the reversibility scan actually listed files (vacuity guard)"
    assert_not_contains "$rows" "memory-dangling-index" \
        "the generated index names no file that does not exist (AC3)"
    assert_not_contains "$rows" "memory-orphan" \
        "every root-level concept is reachable from the generated index (AC3)"
    assert_not_contains "$rows" "okf-version-drift" \
        "the stamped version matches the pin, so the bundle does not read as drifted"
    assert_not_contains "$rows" "okf-reserved-file-structure" \
        "the generated index.md carries only the okf_version §8 permits"
}
