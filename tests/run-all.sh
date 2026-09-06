#!/usr/bin/env bash
# Single entry point for the librarian test suite.
#
# Runs, in order:
#   1. Manifest validation (node tests/validate-manifests.mjs)
#   1b. Workflow helper unit tests (node tests/validate-workflow-helpers.mjs)
#   2. Harness self-test (tests/validate-harness.sh)
#   3. Skill/agent structural lint (tests/lint-skills-agents.sh)
#   4. Skill contract validation (tests/validate-contracts.sh)
#   5. SKILL.md ↔ agent cross-reference integrity (tests/validate-crossrefs.sh)
#   5b. next-issue->ship-issue hand-off ordering (tests/validate-next-issue-handoff.sh)
#   5c. review-harness authority + loud skip (tests/validate-review-authority.sh)
#   5d. status/pr-pending label lifecycle (tests/validate-label-lifecycle.sh)
#   6. Pre-scan empty/missing-input robustness (tests/validate-prescans.sh)
#   7. pre-review-gates scan categories + skip policy (tests/validate-pre-review-gates.sh)
#   7b. review-lens sizing scanner, growth-aware (tests/validate-sizing-scanner.sh)
#   7b2. plan-lens sizing scanner, projection-aware (tests/validate-plan-lens.sh)
#   7c. non-lossy split verification (tests/validate-split-verify.sh)
#   8. codebase-audit issue-template sync (tests/validate-template-sync.sh)
#   8b. audit project-source integrity gate (tests/validate-audit-trust-gate.sh)
#   9. shared scanner sync (tests/validate-shared-scanner-sync.sh)
#   9b. scanner test-file classification (tests/validate-scanner-classification.sh)
#   9c. check-ai-config detector fixtures (tests/validate-checker-detectors.sh)
#   9c2. agnix→TSV normalizer (tests/validate-agnix-normalize.sh)
#   9c3. agnix→checker wiring contract (tests/validate-agnix-checker-wiring.sh)
#   9c4. agnix error-free (tests/lint-agnix-clean.sh)
#   9c4a. agnix gate helper units (tests/validate-agnix-helpers.sh)
#   9c5. ship-issue autonomy-level contract (tests/lint-ship-autonomy-contract.sh)
#   9d. check-docs-* detector fixtures (tests/validate-docs-detectors.sh)
#   9e. check-security + check-code-health detector fixtures (tests/validate-source-detectors.sh)
#   9e1a. OWASP Top 10 coverage map (tests/validate-owasp-coverage.sh)
#   9e2. check-lifecycle detector fixtures (tests/validate-lifecycle-detectors.sh)
#   9e3. check-decomposition detector fixtures (tests/validate-decomposition-detectors.sh)
#   9e4. check-okf-conformance detector fixtures (tests/validate-okf-detectors.sh)
#   9e5. audit-memory semantic-pass contract (tests/validate-memory-semantics.sh)
#   9f. dev-core loop-* + drift-detect detector fixtures (tests/validate-loop-detectors.sh)
#  10. golem-gate-watch feed snapshot (tests/golem-gate-watch.sh)
#  11. Action pin format (tests/lint-action-pins.sh)
#  11b. Shell portability / bash-3.2 clean (tests/lint-shell-portability.sh)
#  11b2. READONLY harness wording (tests/lint-readonly-harness.sh)
#  11b3. Prose-vs-code env var drift (tests/lint-env-var-drift.sh)
#  11b4. Adversarial-review harness refs (tests/lint-harness-refs.sh)
#  11b4a. Review-harness accepted-args-key refs (tests/lint-args-contract-refs.sh)
#  11b5. Plugin prose budget ratchet (tests/lint-prose-budget.sh)
#  11b5b. Worktree-safe recipes (tests/lint-worktree-recipes.sh)
#  11b6. Prose-budget gate behavior (tests/validate-prose-budget.sh)
#  11b6a. ai-config pre-scan ratchet behavior (tests/validate-ai-config-prescan.sh)
#  11b7. Hook no-op silence (tests/lint-hook-silence.sh)
#  11b8. Scanner extension-dispatch case parity (tests/lint-scanner-case-dispatch.sh)
#  11b8a. Pre-scan input-shape guard (tests/lint-prescan-input-guard.sh)
#  11b8b. is_test_file basename anchoring (tests/lint-test-file-anchoring.sh)
#  11b9. Definition-shaped assertions (tests/lint-definition-assertions.sh)
#  11b10. Scanner language-table consistency (tests/lint-language-table-sync.sh)
#  11c. Python-port contract + bash parity (tests/validate-python-ports.sh)
#  11c2. Pre-scan bash<->python differential (tests/validate-prescan-differential.sh)
#  11c3. Source-level category-slug parity (tests/validate-scanner-category-parity.sh)
#  11c4. check-* deterministic coverage tool (tests/validate-patterns-coverage.sh)
#  11c5. Coverage-corpus completeness (tests/validate-coverage-corpus.sh)
#  11c6. Coverage runner resolution + fail-loud (tests/validate-coverage-runner.sh)
#  11d. Shellcheck — bundled shell scripts (tests/lint-shellcheck.sh)
#  11e. Python lint + format — ruff (tests/lint-python.sh)
#  11e2. Spell check — typos (tests/lint-typos.sh)
#  11f. Lint-gate integrity — runner resolution + skip reporting (tests/validate-lint-gates.sh)
#  11f2. Skip visibility — step summary + agnix install branches (tests/validate-skip-visibility.sh)
#  11f3. run-all verdict reporting — pipe-safe failure (tests/validate-run-all-reporting.sh)
#  11g. bounded-run.sh copy sync (tests/lint-bounded-run-sync.sh)
#  11g2. Generated workflow.js freshness (tests/lint-workflow-js-generated.sh)
#  11g3. Shared workflow.js prelude sync (tests/validate-prelude-sync.sh)
#  11h. Markdown lint — .claude/memory/ (tests/lint-markdown.sh)
#  12. Release toolchain coverage (tests/validate-release.sh)
#  13. seed-worktree-trust path validation (tests/validate-seed-worktree-trust.sh)
#  14. golem/worktree helper scripts (tests/validate-golem-scripts.sh)
#  14a2. journal partial-recovery helper (tests/validate-recover-journal-partials.sh)
#  14a3. workflow wall-time stop decision (tests/validate-workflow-wall-timeout.sh)
#  14a3b. CI-wait stop decision (tests/validate-ci-wait-timeout.sh)
#  14a3c. shared threshold-check library units (tests/validate-threshold-check.sh)
#  14a4. review convergence stop decision (tests/validate-review-convergence.sh)
#  14a5. review routing decision (tests/validate-review-route.sh)
#  14b. autonomy-resolver decision table + parity (tests/validate-autonomy-resolve.sh)
#  14b1. measure-spawn-prefix accounting (tests/validate-measure-spawn-prefix.sh)
#  14c. golem-notify Notification hook (tests/validate-golem-notify.sh)
#  14c1. bash-guard PreToolUse hook (tests/validate-bash-guard.sh)
#  14c1a. bash-guard main-session worktree rule (tests/validate-bash-guard-worktree.sh)
#  14c1b. worktree-scope PreToolUse hook (tests/validate-worktree-guard.sh)
#  14c1c. read-scope PreToolUse hook (tests/validate-read-scope-guard.sh)
#  14c1. golem-resolve clearing-signal helper (tests/validate-golem-resolve.sh)
#  14c2. golem-inbox brokered gate reverse channel (tests/validate-golem-inbox.sh)
#  14d. golem-watch streaming dispatcher (tests/validate-golem-watch.sh)
#  14e. token-cost reconciliation harness (tests/validate-token-report.sh)
#  14f. context-budget session-length signal (tests/validate-context-budget.sh)
#  14g. Ephemeral-port allocation + retry (tests/validate-free-port.sh)
#  14h. Coverage-driver listener start attempt (tests/validate-cov-listener.sh)
#  14i. Status-label transition ordering (tests/validate-label-transition.sh)
#
# Each stage is run to completion (no early exit) so a failure in one still
# lets the others report. Exits non-zero if any stage fails. No Docker; node +
# bash + coreutils only (jq is used opportunistically by the contract gate).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Scrub git's hook-exported environment ONCE for the whole suite. A git hook
# (lefthook pre-push runs this entry point) exports GIT_DIR / GIT_WORK_TREE /
# GIT_INDEX_FILE / … into its child's environment; a test that shells out to
# `git` for a sandbox it built with `cd $sb` then silently resolves against the
# OUTER repo instead, because an inherited GIT_DIR overrides cwd-based discovery.
# That is a whole CLASS of "passes on a bare `bash tests/run-all.sh`, fails under
# `git push`" flakes (each individual test also scrubs where it must, but a
# missed site reopens it — so we belt-and-suspenders scrub here at the single
# entry point CI and the hook share, making the suite hook-environment-agnostic).
# `git rev-parse` any value we need is re-derived cwd-locally by the tests
# themselves. Unexport, don't just blank: a blank GIT_DIR="" still overrides
# discovery. Names mirror config.sh's PATH-redirect scrub class (#279/#328).
for _gv in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    unset "$_gv" 2>/dev/null || true
done
unset _gv

rc=0

# Names of the stages that FAILED, one per line, accumulated by run_stage (#854).
# A plain newline-delimited string rather than an array: bash-3.2 clean per the
# repo's portability floor, and the summary wants it as text anyway.
failed_stages=""

# Reserved exit code a stage returns to mean "did NOT run" (see run_stage below).
# Kept in sync with the same constant in tests/lint-python.sh.
SKIP_EXIT_CODE=77

# Diagnostic markers. A stage that hangs otherwise takes the whole job to the CI
# job-level timeout (15m) with no indication of WHICH stage stalled — and GitHub
# purges timed-out-job logs, so the culprit is unrecoverable afterward. The
# `[>>] <stage> :: entering at HH:MM:SS` line makes the LAST such line in the live
# log name the hung stage; `[ok] <stage> (Ns)` gives per-stage elapsed for
# spotting a slow (not yet hung) stage before it crosses the limit.
#
# NB: deliberately NO per-stage `timeout` wrapper. Some stages
# (validate-golem-watch.sh) deliver a GROUP signal (`kill -INT -<pgid>`) to
# exercise cleanup traps; wrapping the stage in `timeout`/`setsid` perturbs the
# process-group topology that delivery depends on and can make an escaped SIGINT
# kill run-all itself (exit 130). Markers alone name the culprit without touching
# signal behaviour — the robust minimal win. (A safe per-stage kill-budget is a
# follow-up once the golem-watch group-signal path is itself made CI-robust.)
#
# Skip reporting (#538): a stage that could not run — its linter is absent —
# exits with the reserved sentinel SKIP_EXIT_CODE (77, the autotools SKIP
# convention) and is rendered `[SKIP] … did not run`, NOT `[ok]`. Before this,
# tests/lint-python.sh's skip-if-absent branch exited 0 and the summary printed
# `[ok] Python lint + format (ruff) (0s)` — indistinguishable from a real pass,
# so the gate sat vacuous and unnoticed on a host with no ruff. A skip does not
# fail the suite (rc is untouched); it just stops lying about having run. Any
# future skip-if-absent gate gets the same treatment by returning 77.
#
# Step-summary escalation (#741). The `[SKIP]` line above fixes the confusion
# between "passed" and "did not run" only for someone READING the log. A gate
# that has quietly stopped running for weeks still looks like a gate that keeps
# passing to anyone glancing at a green check — the log line is buried in
# thousands of others and nobody scrolls a job that succeeded. So on GitHub the
# skip is also written to $GITHUB_STEP_SUMMARY, which renders on the run page
# itself. That is the whole point of the sentinel carried one surface further
# out: 77 stopped the gate lying to the log, this stops it lying to the summary.
#
# Emission is conditional on $GITHUB_STEP_SUMMARY being set and non-empty, so a
# local `just test` is completely unaffected — no file is created, nothing is
# printed differently. The `:-` is load-bearing, not defensive style: this
# script runs under `set -u` (above), where a bare `$GITHUB_STEP_SUMMARY` off
# GitHub is a FATAL unbound-variable error that would abort the whole suite at
# the first skipped gate. `:-` covers unset and empty in the same test.
#
# The header is written LAZILY, on the first skip only, tracked by a plain flag
# variable. Two properties, both deliberate: a run with no skips adds no section
# at all (an empty "Skipped gates" heading would be its own small lie), and a
# run with several adds one heading over a list rather than repeating it. A
# plain string flag rather than an associative array keeps this bash-3.2 clean
# per the repo's portability floor.
_skips_header_written=""

# Append one skipped stage to the GitHub run-page summary. No-op off GitHub.
#
# Failures are absorbed with `|| true`: the summary is a REPORTING nicety, and a
# read-only or full $GITHUB_STEP_SUMMARY must never turn a skipped stage into a
# failed suite. Losing the line is the correct degradation — the `[SKIP]` stdout
# line above still carries the signal.
#
# `2>/dev/null` comes BEFORE the append, and the order is load-bearing. Bash
# applies redirections left to right, so the familiar `>>"$f" 2>/dev/null`
# spelling opens the file FIRST — and when that open fails, the shell's
# "Is a directory" / "Permission denied" diagnostic is written to the stderr
# still in effect, i.e. the terminal. The failure is absorbed but its noise is
# not, which puts an alarming-looking error in the middle of a suite that is
# otherwise fine. Redirecting stderr first means the diagnostic lands in
# /dev/null along with everything else.
#
# `${_skips_header_written:-}` BELOW IS NOT BELT-AND-BRACES. The function's first
# line already guards $GITHUB_STEP_SUMMARY defensively; reading the flag bare on
# the very next line contradicted that, and under `set -u` an out-of-scope read
# is fatal rather than falsy. The top-level initialisation above covers the
# normal runner path — but this function is routinely SLICED out of this file
# with `sed` and eval'd in isolation (validate-skip-visibility.sh and
# validate-lint-gates.sh both do it), and a sed-extracted function body does not
# carry a top-level assignment. So every slicer had to hand-carry the
# declaration or die; matching the guard style retires that for all of them.
#
# The bug could only ever appear on CI: the whole branch is gated on
# $GITHUB_STEP_SUMMARY, which is set on a GitHub runner and nowhere else, so a
# local run returns before touching the flag. tests/validate-skip-visibility.sh
# pins it — deliberately slicing the function WITHOUT the initialisation.
note_skip_in_step_summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    if [ -z "${_skips_header_written:-}" ]; then
        _skips_header_written=1
        {
            printf '\n### Skipped gates\n\n'
            printf 'These gates did NOT run — their tooling was unavailable. '
            printf 'A gate that skips persistently is not a gate.\n\n'
        } 2>/dev/null >>"$GITHUB_STEP_SUMMARY" || true
    fi
    printf -- '- **%s** — did not run (exit %s)\n' "$1" "$SKIP_EXIT_CODE" \
        2>/dev/null >>"$GITHUB_STEP_SUMMARY" || true
}

run_stage() {
    local label="$1"
    shift
    printf '\n========================================\n'
    printf '  %s\n' "$label"
    printf '========================================\n'
    printf '[>>] %s :: entering at %s\n' "$label" "$(date -u +%H:%M:%S 2>/dev/null || echo '?')"
    local _start _end _elapsed
    _start="$(date +%s 2>/dev/null || echo 0)"
    # Capture the exit STATUS, not just pass/fail: 77 is a third outcome and an
    # `if "$@"; then` discards the code that distinguishes it from a failure.
    local _rc=0
    "$@" || _rc=$?
    _end="$(date +%s 2>/dev/null || echo 0)"
    _elapsed=$((_end - _start))
    if [ "$_rc" -eq 0 ]; then
        printf '[ok] %s (%ss)\n' "$label" "$_elapsed"
    elif [ "$_rc" -eq "$SKIP_EXIT_CODE" ]; then
        printf '[SKIP] %s — did not run (%ss)\n' "$label" "$_elapsed"
        note_skip_in_step_summary "$label"
    else
        printf '[FAIL] %s (%ss)\n' "$label" "$_elapsed"
        rc=1
        # `:-` so run_stage stays self-contained. The suite always initialises
        # failed_stages above, but tests/validate-lint-gates.sh SLICES this
        # function out of the source and eval's it alone under `set -u`, where a
        # bare $failed_stages is a fatal unbound-variable error — which would
        # break that gate's pass/fail rendering cases from a distance.
        failed_stages="${failed_stages:-}${label}
"
    fi
}

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
run_stage "golem-gate-watch feed snapshot" bash "$SCRIPT_DIR/golem-gate-watch.sh"
run_stage "Action pin format" bash "$SCRIPT_DIR/lint-action-pins.sh"
run_stage "Namespaced slash-command refs" bash "$SCRIPT_DIR/lint-command-refs.sh"
run_stage "Shell portability (bash 3.2 clean)" bash "$SCRIPT_DIR/lint-shell-portability.sh"
# Regex-dialect probe (#684). Here it asserts only the POSIX baseline — the
# spellings #679 migrated TO — which must hold on every host; its word-boundary
# rows are informational and never fail. The answer it exists to produce comes
# from the macos-latest `bsd-probe` job in ci.yml, since this host is GNU. Run
# locally too so the probe cannot rot unnoticed between macOS runs.
run_stage "Regex dialect probe (POSIX baseline)" bash "$SCRIPT_DIR/probe-bsd-regex.sh"
# ...and the probe's own reporting logic. Running the probe above exercises only
# its SUPPORTED/require-pass paths on a GNU host; this forces the UNSUPPORTED,
# ERROR and require-FAIL branches, which are the ones carrying the signal.
run_stage "Regex-probe reporting integrity" bash "$SCRIPT_DIR/validate-regex-probe.sh"
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
# Structural backstop for the extension-dispatch half of that parity (#754). The
# behavioral suites below can only pin the languages their corpus happens to
# contain, and a mutation round showed arms revert INDEPENDENTLY — so this reads
# the source instead, and covers every arm at every site.
run_stage "Scanner extension-dispatch case parity" bash "$SCRIPT_DIR/lint-scanner-case-dispatch.sh"
run_stage "Pre-scan input-shape guard" bash "$SCRIPT_DIR/lint-prescan-input-guard.sh"

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
run_stage "Python-port contract + bash parity" bash "$SCRIPT_DIR/validate-python-ports.sh"
run_stage "Pre-scan bash<->python differential" bash "$SCRIPT_DIR/validate-prescan-differential.sh"
run_stage "Source-level category-slug parity" bash "$SCRIPT_DIR/validate-scanner-category-parity.sh"
run_stage "check-* deterministic coverage tool" bash "$SCRIPT_DIR/validate-patterns-coverage.sh"
run_stage "Coverage-corpus completeness" bash "$SCRIPT_DIR/validate-coverage-corpus.sh"
run_stage "Coverage runner resolution + fail-loud" bash "$SCRIPT_DIR/validate-coverage-runner.sh"
run_stage "Shellcheck (bundled shell scripts)" bash "$SCRIPT_DIR/lint-shellcheck.sh"
run_stage "Python lint + format (ruff)" bash "$SCRIPT_DIR/lint-python.sh"
run_stage "Spell check (typos)" bash "$SCRIPT_DIR/lint-typos.sh"
run_stage "Lint-gate integrity (resolution + skip reporting)" bash "$SCRIPT_DIR/validate-lint-gates.sh"
run_stage "Skip visibility (step summary + agnix install branches)" bash "$SCRIPT_DIR/validate-skip-visibility.sh"
run_stage "run-all verdict reporting (pipe-safe failure)" bash "$SCRIPT_DIR/validate-run-all-reporting.sh"
run_stage "bounded-run.sh copy sync" bash "$SCRIPT_DIR/lint-bounded-run-sync.sh"
run_stage "Generated workflow.js freshness" bash "$SCRIPT_DIR/lint-workflow-js-generated.sh"
run_stage "Shared workflow.js prelude sync" bash "$SCRIPT_DIR/validate-prelude-sync.sh"
run_stage "Markdown lint (.claude/memory/)" bash "$SCRIPT_DIR/lint-markdown.sh"
run_stage "Release toolchain coverage" bash "$SCRIPT_DIR/validate-release.sh"
run_stage "seed-worktree-trust path validation" bash "$SCRIPT_DIR/validate-seed-worktree-trust.sh"
run_stage "golem/worktree helper scripts" bash "$SCRIPT_DIR/validate-golem-scripts.sh"
run_stage "journal partial-recovery helper" bash "$SCRIPT_DIR/validate-recover-journal-partials.sh"
run_stage "workflow wall-time stop decision" bash "$SCRIPT_DIR/validate-workflow-wall-timeout.sh"
run_stage "CI-wait stop decision" bash "$SCRIPT_DIR/validate-ci-wait-timeout.sh"
run_stage "shared threshold-check library units" bash "$SCRIPT_DIR/validate-threshold-check.sh"
run_stage "review convergence stop decision" bash "$SCRIPT_DIR/validate-review-convergence.sh"
run_stage "review routing decision" bash "$SCRIPT_DIR/validate-review-route.sh"
run_stage "autonomy-resolver decision table + parity" bash "$SCRIPT_DIR/validate-autonomy-resolve.sh"
run_stage "measure-spawn-prefix accounting" bash "$SCRIPT_DIR/validate-measure-spawn-prefix.sh"
run_stage "golem-notify Notification hook" bash "$SCRIPT_DIR/validate-golem-notify.sh"
run_stage "golem-event-listener receiver" bash "$SCRIPT_DIR/validate-golem-event-listener.sh"
run_stage "bash-guard PreToolUse hook" bash "$SCRIPT_DIR/validate-bash-guard.sh"
run_stage "bash-guard main-session worktree rule" bash "$SCRIPT_DIR/validate-bash-guard-worktree.sh"
run_stage "worktree-scope PreToolUse hook" bash "$SCRIPT_DIR/validate-worktree-guard.sh"
run_stage "read-scope PreToolUse hook" bash "$SCRIPT_DIR/validate-read-scope-guard.sh"
run_stage "golem-resolve clearing-signal helper" bash "$SCRIPT_DIR/validate-golem-resolve.sh"
run_stage "golem-inbox brokered gate reverse channel" bash "$SCRIPT_DIR/validate-golem-inbox.sh"
run_stage "golem-watch streaming dispatcher" bash "$SCRIPT_DIR/validate-golem-watch.sh"
run_stage "token-cost reconciliation harness" bash "$SCRIPT_DIR/validate-token-report.sh"
run_stage "context-budget session-length signal" bash "$SCRIPT_DIR/validate-context-budget.sh"
run_stage "ephemeral-port allocation + retry" bash "$SCRIPT_DIR/validate-free-port.sh"
run_stage "coverage-driver listener start attempt" bash "$SCRIPT_DIR/validate-cov-listener.sh"
# The ORDERING of a status-label transition (#636/#921): add first, remove only
# on success, so a failed add can never strip the existing label and leave an
# issue briefly re-selectable by another golem. Its fixtures point at a label
# that does not exist, which is what keeps them discriminating now that #921 has
# created the two that were missing.
run_stage "status-label transition ordering" bash "$SCRIPT_DIR/validate-label-transition.sh"

# Render the end-of-run verdict (#854).
#
# WHY THE FAILURE HALF ALSO GOES TO STDERR. The natural way to read a suite that
# emits thousands of lines is `bash tests/run-all.sh | tail -45` — and a pipeline
# exits with the status of its LAST command, so the caller sees `tail`'s 0 no
# matter how red the suite was. A script cannot fix that from the inside: the
# `set -o pipefail` that would is a property of the INVOKING shell. What it can
# do is make the failure impossible to lose. stderr is not part of a stdout-only
# pipe, so mirroring the verdict there puts it on the terminal even when stdout
# has been piped, redirected, or truncated by `head`. Observed failure this
# closes: a run whose "Markdown lint (.claude/memory/)" stage failed reported
# exit 0 through `| tail`, and only a ~9-minute re-run with output captured to a
# file revealed it.
#
# This is the 77/[SKIP] hazard reached by another route — "a silent skip is
# indistinguishable from a pass" — except in the more dangerous direction, green
# when red, which is what an agent or script keys off before committing.
#
# THE PASSING PATH STAYS SILENT ON STDERR, deliberately. A mirror that also
# announced success would put text on stderr on every green run, which trains
# every caller to ignore the stream and costs exactly the signal this exists to
# add. Failure is the only thing worth interrupting for.
#
# THE FAILED-STAGE NAMES PRINT LAST, after the banner, for the same reason the
# mirror exists: `| tail -N` keeps the END of the output, so putting the list
# there means a truncating reader sees WHICH stage died rather than only that
# something did. stdout keeps the full verdict too — unchanged for anyone
# already reading it.
print_summary() {
    local _line
    printf '\n========================================\n'
    if [ "$rc" -eq 0 ]; then
        printf '  All test stages passed\n'
        printf '========================================\n'
        return 0
    fi
    printf '  One or more test stages FAILED\n'
    printf '========================================\n'
    printf '%s' "${failed_stages:-}" | while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        printf '  [FAIL] %s\n' "$_line"
    done
    printf '\nExit code is %s. NOTE: piping this suite (`| tail`, `| grep`)\n' "$rc"
    printf 'discards it — the pipeline reports the LAST command status. Capture\n'
    printf 'instead:  bash tests/run-all.sh > /tmp/run.log 2>&1; echo $?\n'
}

# Emit the verdict on every stream that must carry it. The stream DECISION lives
# here rather than at the call site so it is testable: tests/validate-run-all-
# reporting.sh slices this function out of the source and runs it over synthetic
# stages. A call site that inlined `|| print_summary >&2` would leave the test
# supplying the mirror itself — the fixture would then pass with the mirror
# removed, which is the tautology this split exists to prevent.
emit_summary() {
    print_summary
    # The failure half again on stderr, which a stdout-only pipe cannot swallow.
    [ "$rc" -eq 0 ] || print_summary >&2
}

emit_summary

exit "$rc"
