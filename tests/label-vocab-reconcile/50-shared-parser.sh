# shellcheck shell=bash
# ONE PARSER, TWO CALLERS (#663) — plus the cross-references each half owes the
# other, and the workflow's posture.
#
# Sourced, not executed; see tests/validate-label-vocab-reconcile.sh.
#
# The reconciler and tests/lint-status-label-refs.sh must derive the same
# declared vocabulary from the same tree. Byte identity of two awk blocks was
# explicitly NOT the contract (#836) — deriving the same answer is.

test_refactored_offline_gate_still_enforces_both_rules() {
    local box out rc=0
    # EXECUTE the refactored gate, don't grep it. The diff replaced its inline awk
    # with the shared library, and grepping for "label-vocab.sh" proves only that
    # the source mentions the file — not that Rule 1, Rule 2, or the new
    # missing-library branch still behave. A verbatim code move is exactly the
    # change most likely to look right and run wrong.
    box="$(command mktemp -d)"
    SANDBOXES="$SANDBOXES $box"
    command mkdir -p "$box/plugins/p/skills/s" "$box/bin/lib" "$box/tests"
    command cp "$VOCAB_LIB" "$box/bin/lib/label-vocab.sh"
    command cp "$LINT_SH" "$box/tests/lint-status-label-refs.sh"
    command printf 'labels:\n  - name: status/in-progress\n' \
        >"$box/plugins/p/skills/s/metadata.yml"

    # Clean corpus: the one referenced label is declared -> exit 0.
    command printf 'Use the `status/in-progress` label.\n' >"$box/plugins/p/skills/s/SKILL.md"
    out="$(/usr/bin/env -uBASH_ENV "$REAL_BASH" --noprofile --norc \
        "$box/tests/lint-status-label-refs.sh" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "the refactored gate passes a clean fixture"

    # Rule 1: an UNDECLARED reference must still be caught through the shared parser.
    rc=0
    command printf 'Also `status/ghost` here.\n' >>"$box/plugins/p/skills/s/SKILL.md"
    out="$(/usr/bin/env -uBASH_ENV "$REAL_BASH" --noprofile --norc \
        "$box/tests/lint-status-label-refs.sh" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "Rule 1 still fires after the parser was extracted"
    assert_contains "$out" "status/ghost" "and names the undeclared label"

    # RULE 2, which this test's NAME promised and its body did not deliver. The
    # extraction only touched Rule 1's parser, so Rule 2 was never at risk — but the
    # name asserted it had been re-verified, and a name claiming coverage that does
    # not exist is worse than the omission: it stops the next reader from checking.
    # Planting a combined add+remove call is a two-line fixture, so the honest fix is
    # to make the name true rather than to narrow it.
    rc=0
    command printf 'Run `gh issue edit 1 --add-label a --remove-label b` to move it.\n' \
        >>"$box/plugins/p/skills/s/SKILL.md"
    out="$(/usr/bin/env -uBASH_ENV "$REAL_BASH" --noprofile --norc \
        "$box/tests/lint-status-label-refs.sh" 2>&1)" || rc=$?
    assert_exit 1 "$rc" "Rule 2 still fires after the refactor"
    assert_contains "$out" "COMBINED add+remove" "and names the violated rule"
    # Its documented ellipsis carve-out must survive too: prose that quotes the
    # forbidden shape in order to FORBID it is not an instance of it.
    command rm -f "$box/plugins/p/skills/s/SKILL.md"
    rc=0
    command printf 'Use `status/in-progress`. Never `gh issue edit --add-label … --remove-label …`.\n' \
        >"$box/plugins/p/skills/s/SKILL.md"
    out="$(/usr/bin/env -uBASH_ENV "$REAL_BASH" --noprofile --norc \
        "$box/tests/lint-status-label-refs.sh" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "the ellipsis carve-out still exempts prose that forbids the pattern"

    # The new fail-loud branch: no library -> exit 2, never an empty vocabulary.
    rc=0
    command rm -f "$box/bin/lib/label-vocab.sh"
    out="$(/usr/bin/env -uBASH_ENV "$REAL_BASH" --noprofile --norc \
        "$box/tests/lint-status-label-refs.sh" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "a missing shared library exits 2, not 0 and not 200 findings"
    assert_contains "$out" "FATAL" "the diagnostic names itself fatal"
}

test_parser_ignores_trailing_comments_and_quotes() {
    local box declared
    box="$(command mktemp -d)"
    SANDBOXES="$SANDBOXES $box"
    command mkdir -p "$box/plugins/p/skills/s"
    # Neither spelling appears in a metadata.yml today. This function is now the
    # ONE source both halves trust, so a corpus edit adding either would otherwise
    # produce a false finding in the offline gate AND the reconciler at once.
    {
        command printf 'labels:\n'
        command printf '  - name: status/plain\n'
        command printf '  - name: status/commented  # a triage note\n'
        command printf "  - name: 'status/singlequoted'\n"
        command printf '  - name: "status/doublequoted"\n'
    } >"$box/plugins/p/skills/s/metadata.yml"

    declared="$(
        # shellcheck source=bin/lib/label-vocab.sh
        . "$VOCAB_LIB"
        declared_status_labels "$box/plugins"
    )"
    assert_contains "$declared" "status/commented" "a trailing comment is trimmed off the name"
    assert_not_contains "$declared" "triage note" "the comment text never becomes part of a label"
    assert_not_contains "$declared" "#" "no label carries a comment marker"
    assert_contains "$declared" "status/singlequoted" "single quotes are stripped"
    assert_contains "$declared" "status/doublequoted" "double quotes are stripped"
    assert_not_contains "$declared" "'" "no label carries a stray quote"
}

test_a_hash_inside_a_label_name_is_not_a_comment() {
    local box declared
    box="$(command mktemp -d)"
    SANDBOXES="$SANDBOXES $box"
    command mkdir -p "$box/plugins/p/skills/s"
    # YAML only starts a comment at a `#` PRECEDED BY WHITESPACE, and GitHub
    # permits `#` inside a label name. The first draft of the comment trim matched
    # any `#`, which silently truncated the valid name `status/a#b` to `status/a` —
    # a name that would then read as "declared but absent from the repo" on every
    # single run. Caught by probing the trim's edge cases rather than by a test of
    # the happy path, so both arms are pinned here: a real comment goes, an
    # in-name hash stays.
    {
        command printf 'labels:\n'
        command printf '  - name: status/hash#inname\n'
        command printf '  - name: "status/quoted#hash"  # a real comment\n'
        command printf '  - name: status/trailing  # another real comment\n'
    } >"$box/plugins/p/skills/s/metadata.yml"

    declared="$(
        # shellcheck source=bin/lib/label-vocab.sh
        . "$VOCAB_LIB"
        declared_status_labels "$box/plugins"
    )"
    assert_contains "$declared" "status/hash#inname" \
        "an unquoted in-name hash survives (it is not a comment)"
    assert_contains "$declared" "status/quoted#hash" \
        "a quoted in-name hash survives while its trailing comment is removed"
    assert_not_contains "$declared" "a real comment" "the real comment text is gone"
    assert_contains "$declared" "status/trailing" "and its name is left intact"
    assert_not_contains "$declared" "status/trailing " "with no trailing whitespace"
}

# --- one parser, two callers (#663) -----------------------------------------

test_shared_parser_is_the_only_parser() {
    # The reconciler and the offline gate must both go through the library. A
    # second inline awk block in either would be the duplication the extraction
    # removed, and it would drift silently.
    assert_file_contains "$RECONCILE_SH" "label-vocab.sh" \
        "the reconciler sources the shared parser"
    assert_file_contains "$LINT_SH" "label-vocab.sh" \
        "the offline gate sources the shared parser"
    assert_file_contains "$VOCAB_LIB" "declared_status_labels" \
        "the library defines the shared function"
    # Byte identity of two awk blocks was explicitly the WRONG contract (#836);
    # the right one is that neither caller carries its own copy.
    assert_file_not_contains "$RECONCILE_SH" "name:\[\[:space:\]\]\*status" \
        "the reconciler carries no second copy of the parser"
}

test_both_callers_derive_the_same_vocabulary() {
    local box declared_via_lib
    box="$(make_sandbox status/in-progress status/blocked status/on-hold)"

    # Read the vocabulary through the library exactly as both callers do.
    declared_via_lib="$(
        # shellcheck source=bin/lib/label-vocab.sh
        . "$VOCAB_LIB"
        declared_status_labels "$box/plugins"
    )"
    assert_contains "$declared_via_lib" "status/in-progress" "the parser found the first label"
    assert_contains "$declared_via_lib" "status/on-hold" "the parser found the third label"
    assert_not_contains "$declared_via_lib" "type/fixture" \
        "the parser is scoped to status/*"
    assert_not_contains "$declared_via_lib" "not-a-label-decl" \
        "the parser respects the labels: block boundary"

    # And the reconciler's own count agrees with it.
    stub_gh "$box" ok status/in-progress status/blocked status/on-hold
    run_reconcile "$box"
    assert_contains "$RC_OUT" "metadata.yml\`: **3**" \
        "the reconciler counted exactly what the library returned"
}

# --- the workflow's posture --------------------------------------------------
# AC2 and AC3 are properties of the YAML, and the YAML is the one part this
# suite cannot execute. Asserting them structurally is weaker than running the
# job, and is recorded as such — but a workflow that lost workflow_dispatch, or
# that acquired write permissions, would otherwise regress unnoticed.

test_workflow_is_dispatchable_and_informational() {
    local wf="$REPO_ROOT/.github/workflows/label-vocab-reconcile.yml"
    assert_file_exists "$wf" "the scheduled workflow exists"
    assert_file_contains "$wf" "workflow_dispatch:" \
        "AC2: dispatchable, since the schedule only ever fires on the default branch"
    # AC2's escape hatch must not be cancellable by the cadence it pre-empts. A
    # single concurrency group with an unconditional cancel-in-progress lets a
    # schedule firing seconds after a dispatch kill the dispatch — and the dispatch
    # is the ONLY way to exercise this job or to confirm the token's permissions.
    assert_file_contains "$wf" 'group: label-vocab-reconcile-\${{ github.event_name }}' \
        "the concurrency group is keyed by event, so a schedule cannot cancel a dispatch"
    # Anchored to the SETTING, at line start. The bare phrase also appears in the
    # comment that EXPLAINS why the setting is conditional, so an unanchored
    # not-contains failed on the file's own rationale — the
    # prose-that-forbids-the-pattern-is-not-an-instance-of-it shape this repo already
    # carves out elsewhere.
    assert_file_not_contains "$wf" "^  cancel-in-progress: true" \
        "cancel-in-progress is conditional, never unconditionally true"
    assert_file_contains "$wf" "github.event_name == 'schedule'" \
        "only schedules coalesce; a dispatch someone is waiting on is left alone"

    # THE FORK GUARD. A scheduled workflow also fires on forks of the default
    # branch, where it would compare OUR declared vocabulary against the FORK's
    # label set — every label reading as deleted — and mail the fork owner about it.
    # The workflow's header explains that at length, and nothing asserted it: one
    # deleted line and the job silently starts spamming every fork, with the whole
    # repo green. A documented reason is not a gate.
    assert_file_contains "$wf" "github.repository == 'joshjhall/librarian'" \
        "the fork guard is present (without it a scheduled run mails every fork owner)"
    # Least privilege, the two halves that are easy to drop in an edit.
    assert_file_contains "$wf" "persist-credentials: false" \
        "checkout does not persist credentials (this job only reads)"
    assert_file_contains "$wf" "timeout-minutes:" \
        "the job is time-bounded"
    assert_file_not_contains "$wf" "^      contents: write" \
        "the workflow never grants write access to contents"
    assert_file_contains "$wf" "cron:" "it is scheduled"
    assert_file_contains "$wf" "issues: read" "gh label list needs issues: read"
    # AC3 is structural — it cannot fail a PR because nothing aggregates it. The
    # positive check is that it stays out of ci.yml and out of every shard.
    #
    # THE ABSENCE CHECKS ASSERT THE HAYSTACK EXISTS FIRST. A negated `grep` over a
    # MISSING file succeeds, so `! grep -q X missing.yml` passes for the wrong
    # reason — measured here: typoing the ci.yml path left this whole test green.
    # That is the vacuous-assertion shape a gate's own fixtures are most prone to,
    # and the reason to state the haystack as its own assertion rather than to
    # trust the negation. Same for the shard sweep, whose corpus is asserted
    # non-empty below.
    local ci="$REPO_ROOT/.github/workflows/ci.yml"
    assert_file_exists "$ci" "the ci.yml haystack exists (else the absence check below is vacuous)"
    assert_true "! command grep -q 'label-vocab-reconcile' '$ci'" \
        "AC3: the reconciler is not part of ci.yml's merge-gate aggregation"

    local n_shards
    n_shards="$(command ls "$SCRIPT_DIR"/shards/*.sh 2>/dev/null | command grep -c . || true)"
    assert_true "[ '$n_shards' -gt 0 ]" \
        "the shard corpus is non-empty (else the absence check below is vacuous)"
    assert_true "! command grep -rq 'bin/label-vocab-reconcile' '$SCRIPT_DIR/shards'" \
        "AC3: the scan itself is not a run-all.sh stage (only this behavior gate is)"
    # And the positive half: THIS suite IS dispatched. Absence-only assertions
    # would also pass if nothing about the feature were wired up at all.
    assert_true "command grep -rq 'validate-label-vocab-reconcile' '$SCRIPT_DIR/shards'" \
        "the behavior gate IS dispatched by a shard (absence checks alone prove nothing)"
}

test_offline_gate_names_its_other_half() {
    # AC5: a reader of either half must learn the boundary from the file in front
    # of them, not from an issue.
    assert_file_contains "$LINT_SH" "label-vocab-reconcile.yml" \
        "AC5: the offline gate names the workflow that covers its blind spot"
    assert_file_contains "$RECONCILE_SH" "lint-status-label-refs.sh" \
        "the reconciler names the offline half in return"
}
