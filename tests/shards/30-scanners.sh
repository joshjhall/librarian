# shellcheck shell=bash
# Scanner, detector, contract and prose stages, plus five balance-motivated
# arrivals (#960, re-balanced #964).
#
# The long tail: ~175s across the check-* detector fixtures, the skill and agent
# structural gates, the doc/prose budgets and the manifest sync checks. No
# single stage here dominates.
#
# THIS SHARD NO LONGER ABSORBS NEW GATES FOR FREE. That was true when it ran
# 175s against a 522s critical path; #964 spent that slack deliberately, moving
# 157s off 10-portability and 21s off 20-golem. Measured after the move
# (run 34187725583): 337 / 350 / 260s, i.e. the three legs within ~90s of each
# other instead of ~347s. The headroom that made this the safe place to add a
# gate is the same headroom the re-balance consumed — so measure the three sums
# before adding anything substantial here, and do not treat this header's old
# promise as still operative.
#
# TREAT ANY ABSOLUTE NUMBER HERE AS RUNNER-DEPENDENT. The same stages measured
# 88s/52s pre-move and 59s/34s post-move (differential/shellcheck) with no code
# change between them, so a ±30% swing between runs is normal. What is stable is
# the ORDERING and the fact that no leg dominates; re-measure before concluding a
# shard has grown, and compare sums within one run, never across two.
#
# FIVE STAGES BELOW ARE HERE FOR BALANCE, NOT THEME. They are tagged
# individually at their call sites. Do not reunite them with their thematic
# siblings in 10-portability without re-measuring: that grouping is exactly what
# #964 traded away, and it cost ~157s of wall clock per CI run.
#
# SOURCED by tests/run-all.sh (and by tests/validate-shards.sh with a stub
# run_stage), never executed — hence no shebang. Sourcing with a stub run_stage
# is what lets the partition be checked WITHOUT running the suite: the stub
# records each label instead of dispatching it. There is deliberately no
# second spelling of the label to keep in sync — one call site per stage.
#
# Add a stage HERE, not in run-all.sh — and add it to exactly one shard.

if command -v node >/dev/null 2>&1; then
    run_stage "Manifest validation" node "$SCRIPT_DIR/validate-manifests.mjs"
    run_stage "Workflow helper unit tests" node "$SCRIPT_DIR/validate-workflow-helpers.mjs"
else
    # The ONE skip path that does not flow through run_stage, so it needs the
    # step-summary call explicitly (#741). Without it, an absent node would skip
    # these two stages invisibly on the run page while every other skip-if-absent
    # gate reported itself there — the precise asymmetry this change exists to
    # remove, surviving in the one branch that takes a different route to the
    # same outcome.
    printf '[SKIP] Manifest validation — did not run (node not available)\n'
    note_skip_in_step_summary "Manifest validation"
    printf '[SKIP] Workflow helper unit tests — did not run (node not available)\n'
    note_skip_in_step_summary "Workflow helper unit tests"
fi

run_stage "Harness self-test" bash "$SCRIPT_DIR/validate-harness.sh"
run_stage "Skill/agent structural lint" bash "$SCRIPT_DIR/lint-skills-agents.sh"
run_stage "Skill contract validation" bash "$SCRIPT_DIR/validate-contracts.sh"
run_stage "SKILL.md ↔ agent cross-reference integrity" bash "$SCRIPT_DIR/validate-crossrefs.sh"
run_stage "next-issue->ship-issue hand-off ordering" bash "$SCRIPT_DIR/validate-next-issue-handoff.sh"
run_stage "review-harness authority + loud skip" bash "$SCRIPT_DIR/validate-review-authority.sh"
run_stage "status/pr-pending label lifecycle" bash "$SCRIPT_DIR/validate-label-lifecycle.sh"
run_stage "Pre-scan empty/missing-input robustness" bash "$SCRIPT_DIR/validate-prescans.sh"
run_stage "pre-review-gates scan categories + skip policy" bash "$SCRIPT_DIR/validate-pre-review-gates.sh"
run_stage "review-lens sizing scanner (growth-aware)" bash "$SCRIPT_DIR/validate-sizing-scanner.sh"
run_stage "plan-lens sizing scanner (projection-aware)" bash "$SCRIPT_DIR/validate-plan-lens.sh"
run_stage "non-lossy split verification" bash "$SCRIPT_DIR/validate-split-verify.sh"
run_stage "codebase-audit issue-template sync" bash "$SCRIPT_DIR/validate-template-sync.sh"
run_stage "audit project-source integrity gate" bash "$SCRIPT_DIR/validate-audit-trust-gate.sh"
run_stage "shared scanner sync" bash "$SCRIPT_DIR/validate-shared-scanner-sync.sh"
run_stage "scanner test-file classification" bash "$SCRIPT_DIR/validate-scanner-classification.sh"
run_stage "check-ai-config detector fixtures" bash "$SCRIPT_DIR/validate-checker-detectors.sh"
run_stage "agnix→TSV normalizer" bash "$SCRIPT_DIR/validate-agnix-normalize.sh"
run_stage "agnix→checker wiring" bash "$SCRIPT_DIR/validate-agnix-checker-wiring.sh"
run_stage "agnix error-free" bash "$SCRIPT_DIR/lint-agnix-clean.sh"
run_stage "agnix gate helper units" bash "$SCRIPT_DIR/validate-agnix-helpers.sh"
run_stage "ship-issue autonomy-level contract" bash "$SCRIPT_DIR/lint-ship-autonomy-contract.sh"
run_stage "check-docs-* detector fixtures" bash "$SCRIPT_DIR/validate-docs-detectors.sh"
run_stage "check-security + check-code-health detector fixtures" bash "$SCRIPT_DIR/validate-source-detectors.sh"
run_stage "OWASP Top 10 coverage map" bash "$SCRIPT_DIR/validate-owasp-coverage.sh"
run_stage "check-lifecycle detector fixtures" bash "$SCRIPT_DIR/validate-lifecycle-detectors.sh"
run_stage "check-decomposition detector fixtures" bash "$SCRIPT_DIR/validate-decomposition-detectors.sh"
run_stage "check-okf-conformance detector fixtures" bash "$SCRIPT_DIR/validate-okf-detectors.sh"
run_stage "audit-memory semantic-pass contract" bash "$SCRIPT_DIR/validate-memory-semantics.sh"
run_stage "dev-core loop-* + drift-detect detector fixtures" bash "$SCRIPT_DIR/validate-loop-detectors.sh"
run_stage "Namespaced slash-command refs" bash "$SCRIPT_DIR/lint-command-refs.sh"
run_stage "READONLY harness wording" bash "$SCRIPT_DIR/lint-readonly-harness.sh"
run_stage "Prose-vs-code env var drift" bash "$SCRIPT_DIR/lint-env-var-drift.sh"
run_stage "Adversarial-review harness refs" bash "$SCRIPT_DIR/lint-harness-refs.sh"
# The same prose-drift class, one contract over (#886): KNOWN_ARG_KEYS is the
# authority for the review harness's accepted `args` keys, and six prose copies
# restate it. The #597 runtime guard catches an INVENTED key but is structurally
# blind to a MISSING one, so the subset direction has no other backstop.
run_stage "Review-harness accepted-args-key refs" bash "$SCRIPT_DIR/lint-args-contract-refs.sh"
# Two invariants over the status/* label vocabulary (#921): every label named in
# plugins/**/*.md is declared in some metadata.yml, and no markdown recipe puts
# an add and a remove in ONE call — measured against real gh, that call applies
# the remove and then fails the add, leaving the issue with no status label.
# Offline by construction — a gate that needed `gh` auth would sit on the 77
# sentinel in CI and pre-push alike.
run_stage "Status-label refs + transition shape" bash "$SCRIPT_DIR/lint-status-label-refs.sh"
run_stage "Plugin prose budget (ratchet)" bash "$SCRIPT_DIR/lint-prose-budget.sh"
run_stage "Worktree-safe recipes" bash "$SCRIPT_DIR/lint-worktree-recipes.sh"
run_stage "Prose-budget gate behavior" bash "$SCRIPT_DIR/validate-prose-budget.sh"
# The BEHAVIOR of bin/ai-config-prescan.sh, not the scan itself (#907). The scan
# runs on a schedule (.github/workflows/ai-config-prescan.yml) because #551
# deliberately moved that coverage off the per-PR path; registering the scan here
# would reverse that decision. Same gate-vs-meta-gate split as the two rows above.
run_stage "ai-config pre-scan ratchet behavior" bash "$SCRIPT_DIR/validate-ai-config-prescan.sh"
run_stage "Hook no-op silence" bash "$SCRIPT_DIR/lint-hook-silence.sh"
# Steers definition-shaped assertions to assert_file_defines, so the comment
# explaining a setting can never satisfy the test that the setting exists (#830).
run_stage "Definition-shaped assertions" bash "$SCRIPT_DIR/lint-definition-assertions.sh"
# The same silence-reads-as-a-pass family, one layer up: that gate stops a COMMENT
# satisfying an assertion, this one stops a whole SUITE whose failing assertions
# are never collected. A suite that sources harness.sh and drops its trailing
# `generate_report` prints FAIL lines and exits 0, so run_stage renders it [ok]
# (#899) — the shape a suite split is most likely to introduce (#564, #859).
run_stage "Suite verdict reporting" bash "$SCRIPT_DIR/lint-suite-reporting.sh"
# Structural backstop for the extension-dispatch half of that parity (#754). The
# behavioral suites below can only pin the languages their corpus happens to
# contain, and a mutation round showed arms revert INDEPENDENTLY — so this reads
# the source instead, and covers every arm at every site.
run_stage "Scanner extension-dispatch case parity" bash "$SCRIPT_DIR/lint-scanner-case-dispatch.sh"
run_stage "Pre-scan input-shape guard" bash "$SCRIPT_DIR/lint-prescan-input-guard.sh"

# The evidence-field twin of the guard above, and warranted for the same two
# reasons (#902): truncate_chars is copied byte-identically into 15 files, and
# pre-review-gates.sh carries it with NO .py sibling — so the parity corpus,
# which pairs a .py with its .sh, structurally cannot reach that one.
run_stage "Evidence-field CR strip" bash "$SCRIPT_DIR/lint-evidence-cr-strip.sh"

# The same shape, one predicate over: is_test_file's name arms must match the
# BASENAME, so a DIRECTORY named test_helpers/ can never make real source
# beneath it read as test code. Fixed by hand twice (#568, #836) before anything
# swept the class; byte-identity was the wrong contract for these copies (#836),
# which is what left anchoring unenforced (#866).
run_stage "is_test_file basename anchoring" bash "$SCRIPT_DIR/lint-test-file-anchoring.sh"

# The companion to the stage above: that one pins HOW an extension is spelled in
# bash, this one pins WHICH LANGUAGE it means and that the contract matrix and
# both runtimes agree about it (#622 Phase 0, ADR 0002).
run_stage "Scanner language-table consistency" bash "$SCRIPT_DIR/lint-language-table-sync.sh"
# The same ADR 0002 subset rule, one consumer over (#913). The stage above scans
# the four check-* scanners only, and review-route.sh — which decides whether the
# review fan-out RUNS AT ALL — followed the rule by hand, ungated. Its own gate
# rather than a fifth entry there: that one is shaped around a patterns.{py,sh}
# pair plus a `## Language Support` matrix this file has neither of.
run_stage "review-route.sh extension table" bash "$SCRIPT_DIR/lint-review-route-lang.sh"
run_stage "check-* deterministic coverage tool" bash "$SCRIPT_DIR/validate-patterns-coverage.sh"
run_stage "Coverage-corpus completeness" bash "$SCRIPT_DIR/validate-coverage-corpus.sh"
run_stage "Coverage runner resolution + fail-loud" bash "$SCRIPT_DIR/validate-coverage-runner.sh"
run_stage "Generated workflow.js freshness" bash "$SCRIPT_DIR/lint-workflow-js-generated.sh"
run_stage "Shared workflow.js prelude sync" bash "$SCRIPT_DIR/validate-prelude-sync.sh"
run_stage "Markdown lint (.claude/memory/)" bash "$SCRIPT_DIR/lint-markdown.sh"
run_stage "OKF bundle conformance + health (.claude/memory/)" bash "$SCRIPT_DIR/validate-okf-bundle.sh"
run_stage "OKF bundle gate behavior" bash "$SCRIPT_DIR/validate-okf-bundle-gate.sh"

# --- Balance-motivated arrivals (#964) --------------------------------------
#
# The five stages below do NOT belong to this shard's theme. Four came from
# 10-portability, where they sat beside the indivisible `Shell portability` stage
# and made that leg the slowest at 522s; one came from 20-golem. Moving them cut
# CI wall clock from 542s to 370s (measured, run 34187725583). What remains is
# the Shell-portability floor, which no further rebalance beats.
#
# Each is thematically a language/runtime gate, and each will read as misplaced
# here. That is the trade #964 made knowingly: theme lost to ~157s per run. If
# you move one back, re-measure all three shard sums first — this shard has the
# most slack of the three (260s against 337s and 350s in that run), so it can
# absorb a stage the others cannot, and moving one OUT of here is the change most
# likely to cost wall clock.
#
# None of these sources tests/lib/golem-sandbox.sh, which is why they were
# eligible to move at all: the worktree-mutating suites must stay together in
# 20-golem (see that shard's header, and
# validate-shards.sh::test_worktree_mutating_stages_share_one_shard).
run_stage "Python-port contract + bash parity" bash "$SCRIPT_DIR/validate-python-ports.sh"
run_stage "Pre-scan bash<->python differential" bash "$SCRIPT_DIR/validate-prescan-differential.sh"
run_stage "Shellcheck (bundled shell scripts)" bash "$SCRIPT_DIR/lint-shellcheck.sh"
# The BEHAVIOR of bounded_run, not just the byte-sync of its two copies (#961).
# `bounded-run.sh copy sync` (still in 10-portability) pins that the copies match
# and depend on no GNU coreutils; neither is a claim that the bound works. That
# gap is what let a bound that had stopped bounding the CAPTURE sit unnoticed
# until it cost a 15-minute CI stall. The two are now in different shards — they
# check different things and neither depends on the other's outcome.
run_stage "bounded_run behavior (capture bound)" bash "$SCRIPT_DIR/validate-bounded-run.sh"
run_stage "coverage-driver listener start attempt" bash "$SCRIPT_DIR/validate-cov-listener.sh"
