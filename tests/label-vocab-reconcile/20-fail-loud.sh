# shellcheck shell=bash
# FAIL LOUD — every path that produces an EMPTY comparison must exit 2, never 0.
#
# Sourced, not executed; see tests/validate-label-vocab-reconcile.sh.
#
# These matter more than they look. An empty comparison is indistinguishable from
# "no drift" — the inert-gate shape this repo keeps filing issues about (#538,
# #571, #906). A reconciler that exited 0 when `gh` was unauthenticated would
# report a clean vocabulary every week without ever querying anything. The
# preflight cases (absent `tr`, the derivation guard) live here for the same
# reason: a missing tool silently blanking a finding is the same defect class.

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
    for t in sort comm awk mktemp sed grep rm find cat printf dirname pwd env bash; do
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
    #
    # The count is DERIVED from the script's own GH_LABEL_LIMIT, not written as
    # 500. A literal here would keep passing while testing nothing the moment
    # somebody raised the limit: the shim would emit fewer labels than the page
    # size, the guard would correctly not fire, and the case would assert exit 2
    # against a run that had no reason to refuse.
    local limit
    limit="$(command awk -F= '/^GH_LABEL_LIMIT=/ { print $2; exit }' "$RECONCILE_SH")"
    assert_true "[ -n '$limit' ]" \
        "the fixture read GH_LABEL_LIMIT from the script (a blank limit makes this case vacuous)"
    stub_gh "$box" many "$limit"

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
    # The boundary arm: pads + 1 declared label = limit - 1, one UNDER the guard's
    # `-ge` comparison. Off-by-one matters here and the first draft got it wrong
    # (499 pads + 1 = exactly 500, which TRIPPED the guard), so the count is now
    # DERIVED from the same GH_LABEL_LIMIT the script uses rather than restated as
    # a literal that can drift from it.
    #
    # Built by REWRITING the shim rather than `sed`-splicing it. Two reasons, both
    # measured: a `\n` in a sed REPLACEMENT is GNU-only (BSD sed emits a literal
    # `n`, so this fixture would silently break on macOS — CLAUDE.md § Runtime
    # policy), and appending after the shim's `exit 0` put the extra label PAST the
    # exit, where it never ran.
    local limit pads
    limit="$(command awk -F= '/^GH_LABEL_LIMIT=/ { print $2; exit }' "$RECONCILE_SH")"
    assert_true "[ -n '$limit' ]" \
        "the fixture read GH_LABEL_LIMIT from the script (a blank limit makes this arm vacuous)"
    pads=$((limit - 2))
    # stub_gh normally creates this directory; this case writes the shim itself.
    command mkdir -p "$box/ghbin"
    {
        command printf '#!/usr/bin/env bash\n'
        command printf 'i=1\n'
        command printf 'while [ "$i" -le %s ]; do printf "pad/%%s\\n" "$i"; i=$((i + 1)); done\n' "$pads"
        command printf 'printf "status/in-progress\\n"\n'
        command printf 'exit 0\n'
    } >"$box/ghbin/gh"
    command chmod +x "$box/ghbin/gh"

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "a complete list just under the limit reconciles normally"
    assert_contains "$RC_OUT" "No drift" "and reports clean"
}

test_reconciler_missing_shared_parser_exits_two() {
    local box out rc=0
    # THE TWIN GUARD. Both callers carry a near-identical "shared parser missing"
    # fail-loud branch, and the execution test below covers the OFFLINE gate's copy
    # — but the reconciler's is the half that runs unattended in the scheduled job,
    # and it had no coverage at all. Without the curated FATAL, `.` on a missing
    # file under `set -euo pipefail` aborts with a bare bash "No such file or
    # directory": still non-zero, but not the documented exit-2 contract, and not a
    # diagnostic anyone reading a weekly job's log could act on.
    #
    # The reconciler resolves its library from its OWN $SCRIPT_DIR, not from
    # LABEL_VOCAB_ROOT, so the script itself must be copied into the sandbox for its
    # sibling lib/ to be the one we delete. Copying only the library would leave the
    # real one in place and the guard would never fire — the case would pass for the
    # wrong reason.
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress
    command mkdir -p "$box/bin/lib"
    command cp "$RECONCILE_SH" "$box/bin/label-vocab-reconcile.sh"
    command cp "$VOCAB_LIB" "$box/bin/lib/label-vocab.sh"

    # Control: the copied script works while its sibling library is present, so the
    # failure below is attributable to the deletion and not to the copy.
    out="$(/usr/bin/env -uBASH_ENV PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$box/bin/label-vocab-reconcile.sh" 2>&1)" || rc=$?
    assert_exit 0 "$rc" "the copied reconciler runs normally with its library present"

    rc=0
    command rm -f "$box/bin/lib/label-vocab.sh"
    out="$(/usr/bin/env -uBASH_ENV PATH="$box/ghbin:$PATH" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$box/bin/label-vocab-reconcile.sh" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "a missing shared parser exits 2, per the documented contract"
    assert_contains "$out" "shared label parser is missing" \
        "the curated diagnostic is emitted, not a bare bash error"
    assert_not_contains "$out" "No drift" "a run with no parser claims nothing"
}

test_shared_library_is_syntactically_valid() {
    local rc=0
    # A syntax error in the sourced library is the "could not run" case this whole
    # design refuses to let pass quietly — and it is reachable by editing a COMMENT,
    # not just code: the awk program is single-quoted in the shell, so an apostrophe
    # in a comment inside it ends the program early. That happened while writing
    # this very file's quote-leniency note, and the reconciler died with
    # "unexpected EOF" at a line far from the edit. `bash -n` catches the whole class
    # for the price of one assertion.
    "$REAL_BASH" -n "$VOCAB_LIB" 2>/dev/null || rc=$?
    assert_exit 0 "$rc" "bin/lib/label-vocab.sh parses (a comment apostrophe can break it)"

    rc=0
    "$REAL_BASH" -n "$RECONCILE_SH" 2>/dev/null || rc=$?
    assert_exit 0 "$rc" "bin/label-vocab-reconcile.sh parses"

    rc=0
    "$REAL_BASH" -n "$LINT_SH" 2>/dev/null || rc=$?
    assert_exit 0 "$rc" "tests/lint-status-label-refs.sh parses"
}

test_missing_tr_fails_loud_instead_of_blanking_a_label() {
    local box out rc=0 t src
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress 'status/x[bad]'

    # `tr` ABSENT, everything else present. This is the arm that made the omission
    # dangerous rather than untidy: md_safe runs inside a command substitution
    # embedded in a larger argument (`emit "- \`$(md_safe …)\`"`), and under `set -e`
    # bash treats a failing substitution as fatal ONLY as the direct RHS of a simple
    # assignment. Measured before the fix: the run did not abort, the label rendered
    # as an EMPTY STRING, and it exited 0 — a finding silently blanked by a missing
    # tool, on the one report whose value is being believed.
    command mkdir -p "$box/notr"
    # `dirname` is in this list even though the preflight does not check it: it runs
    # at line 1 to resolve SCRIPT_DIR, BEFORE the preflight exists to diagnose
    # anything, so omitting it made the mutation run die there instead of at the
    # `tr` check — again a fixture failure impersonating a subject one. The sandbox
    # must supply everything the script needs EXCEPT the one tool under test.
    # `env` and `bash` are here because the gh SHIM's own shebang is
    # `#!/usr/bin/env bash` — without them the shim cannot start, gh "fails", and the
    # run dies at the gh-failure branch rather than at the `tr` check. That is the
    # third distinct layer of this fixture that impersonated a subject failure while
    # only the sandbox was wrong; each was found by re-reading the mutation's actual
    # diagnostic instead of accepting FAIL as proof.
    for t in gh sort comm awk sed grep mktemp find rm cat dirname pwd env bash; do
        src="$(command -v "$t" 2>/dev/null)" || continue
        [ -n "$src" ] || continue
        command ln -sf "$src" "$box/notr/$t" 2>/dev/null || true
    done
    # The gh shim must still resolve, so link it in rather than prepending its dir.
    # A `cp` here fails once `tr` is removed from the preflight during a mutation
    # run (the sandbox dir is built before `cp` is on the stubbed PATH), which made
    # the mutation look like it fired for the right reason when it had not — the
    # fixture-failure-wearing-a-subject-failure shape. A symlink needs no copy.
    command ln -sf "$box/ghbin/gh" "$box/notr/gh"

    out="$(/usr/bin/env -uBASH_ENV PATH="$box/notr" LABEL_VOCAB_ROOT="$box" \
        "$REAL_BASH" --noprofile --norc "$RECONCILE_SH" 2>&1)" || rc=$?
    assert_exit 2 "$rc" "an absent tr exits 2 at the preflight, never 0 with a blank label"
    assert_contains "$out" "tr not found" "the diagnostic names the missing tool"
    # The negative half: it must fail BEFORE reporting, not report emptily.
    assert_not_contains "$out" "No drift" "no verdict is emitted"
    assert_not_contains "$out" "- \`\`" "no label is rendered as an empty code span"
}

test_preflight_list_matches_its_own_derivation() {
    local derived missing t
    # THE COMMENT IS EXECUTABLE, SO EXECUTE IT. The preflight's note documents the
    # grep that produces its list, precisely because the previous note CLAIMED to
    # cover "EVERY runtime dependency" while omitting one — twice (`find`, then
    # `tr`). A documented derivation is only better than a claim if something checks
    # that it still holds; otherwise the next `command <tool>` added to either file
    # drifts the same way, and the comment becomes false again.
    #
    # `printf` is excluded as a bash BUILTIN (measured: `command printf` works on an
    # empty PATH), so it is the one derived name legitimately absent from the list.
    derived="$(command grep -hE '^[^#]*command [a-z]' "$RECONCILE_SH" "$VOCAB_LIB" |
        command grep -ohE 'command [a-z][a-z0-9_-]+' | command sed 's/command //' |
        command sort -u | command grep -v '^printf$' || true)"
    assert_not_empty "$derived" "the derivation found tools (a broken recipe proves nothing)"

    missing=""
    for t in $derived; do
        # The list is one line: `for tool in gh sort ... tr; do`. The leading
        # boundary must accept `in ` as well as a space, or the FIRST entry (`gh`)
        # reports as missing — which it did on the first draft, a false positive
        # that would have sent someone editing a correct list.
        command grep -E "^for tool in ([a-z0-9_-]+ )*${t}[ ;]" "$RECONCILE_SH" \
            >/dev/null 2>&1 || missing="$missing $t"
    done
    assert_equals "" "$missing" \
        "every externally-invoked tool is in the fail-loud preflight list"

    # Non-vacuity: the sweep must have inspected a real set, and `tr` — the omission
    # that made this class dangerous — must be among what it checked.
    assert_contains "$derived" "tr" "the derivation includes tr"
    assert_contains "$derived" "find" "and find, the earlier omission"
}
