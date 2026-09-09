#!/usr/bin/env bash
# Behavior gate for bin/label-vocab-reconcile.sh — the scheduled status/* label
# vocabulary reconciler (issue #938).
#
# WHAT THIS PINS, AND WHY IT IS NOT THE RECONCILIATION ITSELF. The reconciler
# needs network + `gh` auth, which is precisely why #921 deferred it to a
# SCHEDULED job (.github/workflows/label-vocab-reconcile.yml) instead of a
# run-all.sh stage: a gate needing auth would spend its life on the 77 skip
# sentinel, rendered `[SKIP] … did not run`, catching nothing. So this suite is
# the META-gate — it exercises the script's COMPARISON LOGIC against fixtures,
# with a stubbed `gh` on PATH. The same gate-vs-meta-gate split the repo already
# runs between lint-prose-budget.sh / validate-prose-budget.sh and
# ai-config-prescan.sh / validate-ai-config-prescan.sh.
#
# THE CENTRAL PROPERTY is that drift in EITHER direction fails the run. A suite
# that only asserted the live repo is currently clean would pass just as happily
# with both comparisons deleted — the reconciler would be inert and nobody would
# know until a deleted label took the pipeline down. Every case below is built on
# the arm that DISAGREES when the logic it targets is removed:
#
#   both directions clean          -> 0    (the control)
#   declared label absent live     -> 1    (the #938 direction; nothing else sees it)
#   live label undeclared          -> 1    (the other direction)
#   BOTH at once                   -> 1, and BOTH named (not collapsed to one row)
#   a live severity/* label        -> 0    (the status/ filter; else red forever)
#   gh absent from PATH            -> 2    (never 0)
#   gh present but failing         -> 2    (never 0 — an auth error is not an empty repo)
#   gh succeeds with no labels     -> 2    (never 0)
#   no declared vocabulary         -> 2    (never 0 — that is a parser regression)
#
# The four exit-2 cases matter more than they look. Each of them produces an
# EMPTY comparison, and an empty comparison is indistinguishable from "no drift"
# — the inert-gate shape this repo keeps filing issues about (#538, #571, #906).
# A reconciler that exited 0 when `gh` was unauthenticated would report a clean
# vocabulary every single week without ever querying anything.
#
# FIXTURES, NOT THE LIVE TREE, AND A STUBBED gh. Each case builds a throwaway
# plugins/ corpus under `mktemp -d`, points the script at it with
# LABEL_VOCAB_ROOT, and puts a `gh` shim first on PATH whose label list is
# whatever the case needs. Nothing here touches the real repo or the network, so
# this suite is legitimately offline and can be a run-all.sh stage while the scan
# itself stays scheduled-only.
#
# ONE PARSER, TWO CALLERS is asserted too: the reconciler and
# tests/lint-status-label-refs.sh must derive the same declared vocabulary from
# the same tree. That is the #663 property the extraction bought, and byte
# identity of two awk blocks was explicitly not the contract (#836).
#
# Pure bash + coreutils. bash-3.2 clean per CLAUDE.md § Runtime policy.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

RECONCILE_SH="$REPO_ROOT/bin/label-vocab-reconcile.sh"
VOCAB_LIB="$REPO_ROOT/bin/lib/label-vocab.sh"
LINT_SH="$REPO_ROOT/tests/lint-status-label-refs.sh"

# The real bash, resolved before any PATH is stubbed — a case that puts a shim
# directory first must still be able to launch the script under test.
REAL_BASH="$(command -v bash)"

SANDBOXES=""
cleanup() {
    local box
    for box in $SANDBOXES; do
        [ -n "$box" ] || continue
        command rm -rf "$box"
    done
}
trap cleanup EXIT

test_suite "status/* label vocabulary reconciler (#938)"

# --- fixture construction ----------------------------------------------------

# make_sandbox <declared-labels...> — build a throwaway tree whose plugins/
# declares exactly the given status/* labels, plus a `gh` shim directory.
# Echoes the sandbox path.
#
# The metadata.yml carries a second, NON-status block and a non-status label so
# the parser's own scoping is exercised by every case rather than only by a
# dedicated one: a parser that ignored the `labels:` boundary, or that matched
# any `status/` substring, would pick up extra entries here and skew the
# comparison in a direction the assertions notice.
make_sandbox() {
    local box meta lbl
    box="$(command mktemp -d)" || return 1
    SANDBOXES="$SANDBOXES $box"

    command mkdir -p "$box/plugins/testplug/skills/thing" "$box/bin"
    meta="$box/plugins/testplug/skills/thing/metadata.yml"

    {
        command printf 'name: thing\n'
        command printf 'description: a fixture skill\n'
        command printf 'labels:\n'
        for lbl in "$@"; do
            command printf '  - name: %s\n' "$lbl"
            command printf '    description: fixture label\n'
        done
        command printf '  - name: type/fixture\n'
        command printf '    description: a non-status label in the same block\n'
        command printf 'other:\n'
        command printf '  - name: status/not-a-label-decl\n'
    } >"$meta"

    command printf '%s\n' "$box"
}

# stub_gh <box> <mode> [labels...] — install a `gh` shim in <box>/ghbin.
#
# modes:
#   ok      print the given labels, exit 0
#   fail    print an auth error to stderr, exit 1
#   empty   print nothing, exit 0
#   many    print N synthetic labels, exit 0 (drives the truncation guard)
stub_gh() {
    local box="$1" mode="$2"
    shift 2
    local shim="$box/ghbin/gh" lbl

    command mkdir -p "$box/ghbin"
    case "$mode" in
        ok)
            {
                command printf '#!/usr/bin/env bash\n'
                for lbl in "$@"; do
                    command printf 'printf "%%s\\n" %s\n' "$lbl"
                done
                command printf 'exit 0\n'
            } >"$shim"
            ;;
        fail)
            {
                command printf '#!/usr/bin/env bash\n'
                command printf 'printf "gh: authentication required\\n" >&2\n'
                command printf 'exit 1\n'
            } >"$shim"
            ;;
        empty)
            {
                command printf '#!/usr/bin/env bash\n'
                command printf 'exit 0\n'
            } >"$shim"
            ;;
        many)
            # $1 = how many labels to emit. The shim reads its own --limit so the
            # fixture cannot drift out of step with the script's page size.
            {
                command printf '#!/usr/bin/env bash\n'
                command printf 'n=%s\n' "$1"
                command printf 'i=1\n'
                command printf 'while [ "$i" -le "$n" ]; do printf "pad/%%s\\n" "$i"; i=$((i + 1)); done\n'
                command printf 'exit 0\n'
            } >"$shim"
            ;;
        *)
            command printf 'stub_gh: unknown mode %s\n' "$mode" >&2
            return 1
            ;;
    esac
    command chmod +x "$shim"
}

# run_reconcile <box> — run the script against the sandbox with the stubbed gh
# first on PATH. Sets RC_OUT and RC_CODE.
#
# `-uBASH_ENV` IS LOAD-BEARING, NOT TIDINESS. This devcontainer sets
# BASH_ENV=/etc/bash_env, which every non-interactive bash sources — and it
# REBUILDS PATH, dropping the shim prefix entirely. Measured while writing this
# suite: without the scrub every case ran the REAL `gh` against the real repo, so
# the stub was inert and ten assertions failed against live label data. It would
# have been invisible in CI, which sets no BASH_ENV (the
# env-scrub-absence-hides-a-path-stub shape). The ATTACHED `-uVAR` spelling is
# required: BSD env has no long options and reads `--unset=VAR` as `-u nset=VAR`
# (CLAUDE.md § Runtime policy (4)).
run_reconcile() {
    local box="$1"
    RC_OUT=""
    RC_CODE=0
    RC_OUT="$(/usr/bin/env -uBASH_ENV PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" 2>&1)" || RC_CODE=$?
}

# --- the control: both directions agree --------------------------------------

test_agreeing_vocabularies_pass() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress status/blocked

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "agreeing declared + live vocabularies exit 0"
    assert_contains "$RC_OUT" "No drift" "the clean run says so explicitly"
    # Non-vacuity: the control must have actually compared a real vocabulary. A
    # parser returning nothing would exit 2, but a comparison over one label
    # would still pass this case while proving much less.
    assert_contains "$RC_OUT" "declared in \`plugins/**/metadata.yml\`: **2**" \
        "the control compared both declared labels, not an empty set"
}

# --- direction 1: declared but deleted from the repo -------------------------
# THE #938 DIRECTION. This is the drift the offline gate is structurally blind
# to, and this suite is the only thing that proves the reconciler sees it.

test_declared_label_absent_from_repo_fails() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "a declared label absent from the repo exits 1"
    assert_contains "$RC_OUT" "Declared but absent" "the report names the direction"
    assert_contains "$RC_OUT" "status/blocked" "the report names the missing label"
    assert_not_contains "$RC_OUT" "No drift" "a failing run never claims no drift"
}

test_every_missing_label_is_named() {
    local box
    box="$(make_sandbox status/in-progress status/blocked status/on-hold)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "two missing labels still exit 1"
    # The SECOND hit is the assertion that matters: a report collapsing N
    # findings to the first one re-creates the suppression bug, and the label
    # nobody notices is exactly the one that takes the pipeline down.
    assert_contains "$RC_OUT" "status/blocked" "the first missing label is named"
    assert_contains "$RC_OUT" "status/on-hold" "the SECOND missing label is named too"
    assert_contains "$RC_OUT" "absent from the repo (2)" "the count reflects both"
}

# --- direction 2: present in the repo but undeclared -------------------------

test_undeclared_live_label_fails() {
    local box
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress status/mystery

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "an undeclared live status/* label exits 1"
    assert_contains "$RC_OUT" "but undeclared" "the report names the direction"
    assert_contains "$RC_OUT" "status/mystery" "the report names the undeclared label"
}

test_all_status_labels_deleted_is_a_finding_not_a_runtime_error() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    # gh SUCCEEDS and returns labels — just no status/* ones. This is the extreme
    # of the #938 direction (somebody deleted the whole family), and it must read
    # as a FINDING (1), not as the runtime failure an empty gh response is (2).
    # The boundary is easy to collapse: a guard on "LIVE is empty" placed after
    # the filter instead of before it would turn the worst real drift event this
    # job exists to catch into a fail-loud exit that names no label at all.
    stub_gh "$box" ok severity/high bug

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "every status/* label deleted is drift (1), not a runtime error (2)"
    assert_contains "$RC_OUT" "status/in-progress" "the first deleted label is named"
    assert_contains "$RC_OUT" "status/blocked" "the second deleted label is named"
    assert_not_contains "$RC_OUT" "FATAL" "a real finding is never dressed as a runtime failure"
}

# --- both directions at once -------------------------------------------------
# A report that stopped at the first direction would pass every case above while
# hiding half of any real drift event.

test_both_directions_reported_together() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress status/mystery

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "drift in both directions exits 1"
    assert_contains "$RC_OUT" "status/blocked" "the missing label is named"
    assert_contains "$RC_OUT" "status/mystery" "the undeclared label is named"
    assert_contains "$RC_OUT" "Declared but absent" "the missing-direction section is present"
    assert_contains "$RC_OUT" "but undeclared" "the undeclared-direction section is present"
}

# --- the status/ filter ------------------------------------------------------
# Load-bearing: `gh label list` returns severity/*, effort/*, type/* and
# component/* too. Unfiltered, the job is red on its first run and gets muted,
# which is the same end state as never having written it.

test_non_status_live_labels_are_ignored() {
    local box
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress severity/critical effort/small \
        type/bug component/workflow bug enhancement

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "non-status live labels do not count as undeclared"
    assert_contains "$RC_OUT" "No drift" "the run is clean"
    assert_not_contains "$RC_OUT" "severity/critical" "a severity label is never reported"
    assert_contains "$RC_OUT" "live \`status/*\` labels in the repo: **1**" \
        "only the status/* label counted"
}

test_non_status_declared_labels_are_ignored() {
    local box
    # make_sandbox always plants `type/fixture` in the same labels: block.
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "a non-status DECLARED label is not demanded of the repo"
    assert_not_contains "$RC_OUT" "type/fixture" "the non-status declaration is never reported"
}

# --- fail loud: every empty-comparison path exits 2, never 0 -----------------

test_missing_gh_exits_two() {
    local box out rc=0
    box="$(make_sandbox status/in-progress)"
    # A PATH holding ONE directory, into which every tool the script needs is
    # symlinked EXCEPT `gh`. Adding /usr/bin wholesale does not work — that is
    # where `gh` itself lives, so the case would pass for the wrong reason (it
    # would find gh and report drift, not absence). The script must fail on the
    # tool it genuinely needs, not on coreutils. BASH_ENV scrubbed for the reason
    # run_reconcile documents: unscrubbed, /etc/bash_env rebuilds a PATH that HAS
    # gh and this case silently asserts nothing.
    local t src
    command mkdir -p "$box/nogh"
    for t in sort comm awk mktemp sed grep rm find cat printf; do
        src="$(command -v "$t" 2>/dev/null)" || continue
        [ -n "$src" ] || continue
        command ln -sf "$src" "$box/nogh/$t" 2>/dev/null || true
    done
    out="$(/usr/bin/env -uBASH_ENV PATH="$box/nogh" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "an absent gh exits 2, NOT 0 — no drift from no query is a lie"
    assert_contains "$out" "gh not found" "the diagnostic names the absent tool"
    assert_contains "$out" "FATAL" "the diagnostic names itself fatal"
    assert_not_contains "$out" "No drift" "a run that never queried claims nothing"
}

test_failing_gh_exits_two() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" fail

    run_reconcile "$box"
    assert_exit 2 "$RC_CODE" "a failing gh exits 2, NOT 1 — an auth error is not drift"
    assert_contains "$RC_OUT" "FATAL" "the diagnostic names itself fatal"
    # The distinction is the whole point: exiting 1 here would report every
    # declared label as deleted, a maximally alarming false positive on the one
    # job whose value is being believed.
    assert_not_contains "$RC_OUT" "Declared but absent" \
        "an auth failure is never reported as deleted labels"
}

test_empty_gh_output_exits_two() {
    local box
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" empty

    run_reconcile "$box"
    assert_exit 2 "$RC_CODE" "a successful gh returning no labels at all exits 2"
    assert_contains "$RC_OUT" "FATAL" "the diagnostic names itself fatal"
}

test_empty_declared_vocabulary_exits_two() {
    local box
    # No status/* labels declared anywhere — a parser regression's signature.
    box="$(make_sandbox)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 2 "$RC_CODE" "an empty declared vocabulary exits 2, not 1"
    assert_contains "$RC_OUT" "FATAL" "the diagnostic names itself fatal"
    assert_contains "$RC_OUT" "parser regression" "the diagnostic says what it suspects"
}

test_missing_plugins_dir_exits_two() {
    local box
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress
    command rm -rf "$box/plugins"

    run_reconcile "$box"
    assert_exit 2 "$RC_CODE" "an absent plugins/ exits 2, not a clean scan"
}

test_unknown_argument_is_rejected() {
    local box out rc=0
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress

    out="$(/usr/bin/env -uBASH_ENV PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" bogus-arg 2>&1)" || rc=$?
    assert_exit 1 "$rc" "an unknown argument is rejected (1, per the documented contract)"
    assert_contains "$out" "unknown argument" "the diagnostic names the problem"
    # It must refuse BEFORE comparing anything — a guard that ran the scan and
    # then complained would have already done the work it was meant to prevent.
    assert_not_contains "$out" "No drift" "the run refuses instead of reconciling"
    assert_not_contains "$out" "vocabulary reconciliation" "no report is emitted at all"
}

test_truncated_label_list_exits_two() {
    local box
    box="$(make_sandbox status/in-progress)"
    # At or above the page size, a missing label is indistinguishable from a
    # truncated page — so the run must refuse (2) rather than report the declared
    # label as deleted (1). This is the same class as the auth-failure case: an
    # incomplete comparison must never wear the costume of a finding.
    stub_gh "$box" many 500

    run_reconcile "$box"
    assert_exit 2 "$RC_CODE" "a possibly-truncated label list exits 2, not 1"
    assert_contains "$RC_OUT" "TRUNCATED" "the diagnostic names truncation"
    assert_not_contains "$RC_OUT" "Declared but absent" \
        "truncation is never reported as a deleted label"
}

test_label_list_below_the_limit_is_not_truncation() {
    local box
    box="$(make_sandbox status/in-progress)"
    # The guard's other arm: a large-but-complete list must still reconcile. A
    # guard keyed on the wrong comparison would refuse every real run, which is
    # the failure mode that gets a scheduled job muted.
    # 498 pad labels PLUS the declared one = 499 raw lines, one UNDER the guard's
    # `-ge` comparison against the 500 page size. Off-by-one matters here and the
    # first draft got it wrong (499 pads + 1 = exactly 500, which trips the guard):
    # this arm is precisely about the boundary, so the count is derived, not eyeballed.
    # The extra label is spliced BEFORE the shim's `exit 0`, not appended after it
    # — appending put it past the exit, where it never ran and the case failed for
    # a fixture reason rather than a subject one.
    stub_gh "$box" many 498
    command sed -i.bak 's|^exit 0$|printf "status/in-progress\\n"\nexit 0|' "$box/ghbin/gh"
    command rm -f "$box/ghbin/gh.bak"

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "a complete list just under the limit reconciles normally"
    assert_contains "$RC_OUT" "No drift" "and reports clean"
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

# --- dispatch ---------------------------------------------------------------

run_test test_agreeing_vocabularies_pass "control: agreeing vocabularies pass"
run_test test_declared_label_absent_from_repo_fails "direction 1: a declared label deleted from the repo fails"
run_test test_every_missing_label_is_named "direction 1: every missing label is named, not just the first"
run_test test_undeclared_live_label_fails "direction 2: an undeclared live status/* label fails"
run_test test_all_status_labels_deleted_is_a_finding_not_a_runtime_error "direction 1: the whole family deleted is drift, not a runtime error"
run_test test_both_directions_reported_together "both directions are reported in one run"
run_test test_non_status_live_labels_are_ignored "the status/ filter ignores other live label families"
run_test test_non_status_declared_labels_are_ignored "the status/ filter ignores other declared labels"
run_test test_missing_gh_exits_two "fail loud: absent gh exits 2, never 0"
run_test test_failing_gh_exits_two "fail loud: failing gh exits 2, never 1"
run_test test_empty_gh_output_exits_two "fail loud: gh returning no labels exits 2"
run_test test_empty_declared_vocabulary_exits_two "fail loud: an empty declared vocabulary exits 2"
run_test test_missing_plugins_dir_exits_two "fail loud: an absent plugins/ exits 2"
run_test test_unknown_argument_is_rejected "usage: an unknown argument is rejected before any work"
run_test test_truncated_label_list_exits_two "fail loud: a possibly-truncated label list exits 2"
run_test test_label_list_below_the_limit_is_not_truncation "the truncation guard does not fire below the limit"
run_test test_shared_parser_is_the_only_parser "one parser: neither caller carries a copy"
run_test test_both_callers_derive_the_same_vocabulary "one parser: both callers derive the same vocabulary"
run_test test_workflow_is_dispatchable_and_informational "the workflow is dispatchable and cannot red a PR"
run_test test_offline_gate_names_its_other_half "each half names the other (AC5)"

generate_report
