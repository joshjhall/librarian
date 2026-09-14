# shellcheck shell=bash
# okf-migrate — the backfill-type transform.
#
# Fragment of tests/validate-okf-migrate.sh. Sourced, not executed.
#
# `type` is OKF's sole always-required key, and §4.1 requires consumers to
# TOLERATE unknown values — so a wrong one is rejected nowhere and propagates
# silently through everything that routes on it. A missing type is one loud
# finding; a wrong one is a lie the ecosystem believes.
#
# That asymmetry is why the headline test here is a NEGATIVE one: the tool must
# refuse to guess. A transform that filled in a plausible value would be worse
# than no transform at all.

test_backfill_lifts_nested_type() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "nested.md" '---
name: nested
metadata:
  type: project
---

Body.'

    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty
    assert_exit 0 "$OKF_RC" "the nested-type case applies cleanly"

    body="$(command cat "$root/nested.md")"
    # THIS IS NOT AN INFERENCE — the value is already written down. The validator
    # reports it missing because §4.1 reads `type` at the TOP LEVEL only. It is
    # also the commonest real migration: #991 moved ~246 files of this shape in
    # this very repo.
    assert_contains "$body" "type: project" "the nested value was lifted to the top level"
    assert_true "[ \"\$(command head -n2 '$root/nested.md' | command tail -n1)\" = 'type: project' ]" \
        "the lifted key sits at the top level of the frontmatter block, not indented"
}

test_backfill_infers_from_directory() {
    local root body
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "feedback/lesson.md" '---
name: lesson
---

Body.'

    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty
    body="$(command cat "$root/feedback/lesson.md")"
    assert_contains "$body" "type: feedback" \
        "a configured directory rule supplies the type (config, not hardcoded convention)"
}

test_ambiguous_type_requires_a_human() {
    local root out before after
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "unmatched.md" '---
name: unmatched
---

No configured rule matches this path.'
    before="$(tree_digest "$root")"

    run_sh check "$root" --transform backfill-type

    out="$OKF_OUT"
    assert_contains "$out" "AMBIGUOUS" "an unmatched concept is reported as ambiguous (AC5)"
    assert_contains "$out" "unmatched.md" "the ambiguity names the file"
    # NAMING THE CANDIDATES is what makes the choice actionable: the human picks
    # from the repo's actual vocabulary rather than inventing a value.
    assert_contains "$out" "candidates:" "the ambiguity offers the configured vocabulary"

    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty

    out="$OKF_OUT"
    assert_exit 3 "$OKF_RC" "an ambiguity is exit 3 — distinct from a refusal (2) and a failure (1)"
    assert_contains "$out" "Nothing was written" "the tool says plainly that it wrote nothing"

    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" "the ambiguous file was NOT guessed at (AC5)"
}

test_ambiguity_blocks_the_whole_apply() {
    local root before after out
    root="$(fresh_bundle "$WORKDIR")"
    # One file the rules DO decide, one they do not.
    write_concept "$root" "feedback/decidable.md" '---
name: decidable
---

Body.'
    write_concept "$root" "undecidable.md" '---
name: undecidable
---

Body.'
    before="$(tree_digest "$root")"

    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty

    out="$OKF_OUT"
    assert_exit 3 "$OKF_RC" "the apply is blocked"

    # NO PARTIAL MIGRATION. The decidable file is left alone too — a bundle half
    # migrated around the files the tool could not decide is harder to reason
    # about than an unmigrated one, and it makes a second run's diff meaningless.
    after="$(tree_digest "$root")"
    assert_equals "$before" "$after" \
        "the DECIDABLE file was not written either — one ambiguity blocks the whole apply (AC5)"
}

test_backfill_reversibility() {
    local root rows
    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the validator drives the reversibility check"
        return
    fi
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "nested.md" '---
name: nested
metadata:
  type: project
---

Body. **Why:** x **How to apply:** y'
    write_concept "$root" "feedback/lesson.md" '---
name: lesson
---

Body. **Why:** x **How to apply:** y'

    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty
    validator_rows "$root"
    rows="$OKF_ROWS"

    assert_true "[ '$OKF_LISTED' -gt 0 ]" \
        "the reversibility scan actually listed files (vacuity guard)"
    # THE CATEGORY THIS TRANSFORM CLAIMS TO FIX must be gone. Asserting on the
    # category rather than on "no rows at all" is deliberate: an unrelated health
    # observation (a missing **Why:** section) is not this transform's business,
    # and folding it in would make the assertion fail for the wrong reason.
    assert_not_contains "$rows" "okf-missing-type" \
        "every concept now carries a top-level type — zero rows for the category (AC3)"
}

test_foreign_vocabulary_needs_no_code_change() {
    local root cfg skill_copy out
    # AC9, and the epic's hard scope boundary (#664): "a repo using entirely
    # different values must get correct results with zero code changes." A repo
    # whose types are nothing like librarian's `user|feedback|project|reference`
    # must be able to state its own vocabulary in thresholds.yml alone.
    #
    # Exercised against a COPY of the skill with an edited config, because
    # editing the shipped one would make every other case in this suite depend
    # on the edit.
    skill_copy="$(command mktemp -d "$WORKDIR/skill.XXXXXX")"
    command cp -R "$SKILL_DIR/." "$skill_copy/"
    cfg="$skill_copy/thresholds.yml"

    # A type this repo has never heard of, plus an INLINE COMMENT on a rule —
    # the parse must drop the comment before reading the value, in both runtimes.
    #
    # The config is written WHOLE rather than patched, so it also pins that a
    # consuming repo's own thresholds.yml is self-contained: nothing here falls
    # back to a librarian default. That means `transforms.applicable` must be
    # stated too — an earlier draft omitted it and backfill-type simply never
    # ran, which is the correct behavior for a config that enables no transform
    # and would have made this case pass vacuously if it had asserted less.
    command printf '%s\n' \
        'transforms:' \
        '  applicable:' \
        '    - backfill-type' \
        '  plan_only:' \
        '    - split-index' \
        'type_inference:' \
        '  rules:' \
        '    - dir:runbooks/* = runbook # an inline comment' \
        '  known_types:' \
        '    - runbook' >"$cfg"

    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "runbooks/deploy.md" '---
name: deploy
---

Body.'

    out="$(PATTERNS_FORCE_BASH=1 OKF_BUNDLE_ROOT="$root" OKF_PINNED_VERSION="0.2" \
        command bash "$skill_copy/migrate.sh" apply --transform backfill-type \
        --confirm --allow-dirty 2>&1)" || :
    assert_output_empty "$out" "a foreign vocabulary applies cleanly, with no complaint"
    assert_contains "$(command cat "$root/runbooks/deploy.md")" "type: runbook" \
        "a repo-specific type is supplied by CONFIG ALONE — no code change (AC9)"

    if [ "$OKF_HAVE_PY" -ne 1 ]; then
        skip_test "python3 >= 3.11 unavailable — the cross-runtime half of this case"
        return
    fi
    local root2 py_body
    root2="$(fresh_bundle "$WORKDIR")"
    write_concept "$root2" "runbooks/deploy.md" '---
name: deploy
---

Body.'
    OKF_BUNDLE_ROOT="$root2" OKF_PINNED_VERSION="0.2" \
        command python3 "$skill_copy/migrate.py" apply --transform backfill-type \
        --confirm --allow-dirty >/dev/null 2>&1 || :
    py_body="$(command cat "$root2/runbooks/deploy.md")"
    assert_equals "$(command cat "$root/runbooks/deploy.md")" "$py_body" \
        "both runtimes read the foreign config identically, inline comment included"
}

test_backfill_is_idempotent() {
    local root first second
    root="$(fresh_bundle "$WORKDIR")"
    write_concept "$root" "feedback/lesson.md" '---
name: lesson
---

Body.'

    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty
    first="$(tree_digest "$root")"
    run_sh apply "$root" --transform backfill-type --confirm --allow-dirty
    second="$(tree_digest "$root")"

    # The second run must find nothing to do — a file that now HAS a type is no
    # longer a candidate, so no second `type:` key can ever be added.
    assert_equals "$first" "$second" "applying backfill-type twice equals applying once (AC4)"
    assert_equals "1" "$(command grep -c '^type:' "$root/feedback/lesson.md")" \
        "the file carries exactly ONE top-level type key after two applies"
}
