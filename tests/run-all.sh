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
#   6. Pre-scan empty/missing-input robustness (tests/validate-prescans.sh)
#   7. pre-review-gates scan categories + skip policy (tests/validate-pre-review-gates.sh)
#   8. codebase-audit issue-template sync (tests/validate-template-sync.sh)
#   8b. audit project-source integrity gate (tests/validate-audit-trust-gate.sh)
#   9. shared scanner sync (tests/validate-shared-scanner-sync.sh)
#   9b. scanner test-file classification (tests/validate-scanner-classification.sh)
#   9c. check-ai-config detector fixtures (tests/validate-checker-detectors.sh)
#   9d. check-docs-* detector fixtures (tests/validate-docs-detectors.sh)
#   9e. check-security + check-code-health detector fixtures (tests/validate-source-detectors.sh)
#   9f. dev-core loop-* + drift-detect detector fixtures (tests/validate-loop-detectors.sh)
#  10. golem-gate-watch feed snapshot (tests/golem-gate-watch.sh)
#  11. Action pin format (tests/lint-action-pins.sh)
#  11b. Shell portability / bash-3.2 clean (tests/lint-shell-portability.sh)
#  11c. Python-port contract + bash parity (tests/validate-python-ports.sh)
#  11c2. Pre-scan bash<->python differential (tests/validate-prescan-differential.sh)
#  11c3. Source-level category-slug parity (tests/validate-scanner-category-parity.sh)
#  11c4. check-* deterministic coverage tool (tests/validate-patterns-coverage.sh)
#  11d. Shellcheck — bundled shell scripts (tests/lint-shellcheck.sh)
#  11e. Python lint + format — ruff (tests/lint-python.sh)
#  12. Release toolchain coverage (tests/validate-release.sh)
#  13. seed-worktree-trust path validation (tests/validate-seed-trust.sh)
#  14. golem/worktree helper scripts (tests/validate-golem-scripts.sh)
#  14a2. journal partial-recovery helper (tests/validate-recover-journal-partials.sh)
#  14a3. workflow wall-time stop decision (tests/validate-workflow-wall-timeout.sh)
#  14b. autonomy-resolver decision table + parity (tests/validate-autonomy-resolve.sh)
#  14c. golem-notify Notification hook (tests/validate-golem-notify.sh)
#  14c1. golem-resolve clearing-signal helper (tests/validate-golem-resolve.sh)
#  14c2. golem-inbox brokered gate reverse channel (tests/validate-golem-inbox.sh)
#  14d. golem-watch streaming dispatcher (tests/validate-golem-watch.sh)
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
run_stage() {
    local label="$1"
    shift
    printf '\n========================================\n'
    printf '  %s\n' "$label"
    printf '========================================\n'
    printf '[>>] %s :: entering at %s\n' "$label" "$(date -u +%H:%M:%S 2>/dev/null || echo '?')"
    local _start _end _elapsed
    _start="$(date +%s 2>/dev/null || echo 0)"
    local _ok=0
    if "$@"; then _ok=1; fi
    _end="$(date +%s 2>/dev/null || echo 0)"
    _elapsed=$((_end - _start))
    if [ "$_ok" = "1" ]; then
        printf '[ok] %s (%ss)\n' "$label" "$_elapsed"
    else
        printf '[FAIL] %s (%ss)\n' "$label" "$_elapsed"
        rc=1
    fi
}

if command -v node >/dev/null 2>&1; then
    run_stage "Manifest validation" node "$SCRIPT_DIR/validate-manifests.mjs"
    run_stage "Workflow helper unit tests" node "$SCRIPT_DIR/validate-workflow-helpers.mjs"
else
    printf '[skip] Manifest validation — node not available\n'
    printf '[skip] Workflow helper unit tests — node not available\n'
fi

run_stage "Harness self-test" bash "$SCRIPT_DIR/validate-harness.sh"
run_stage "Skill/agent structural lint" bash "$SCRIPT_DIR/lint-skills-agents.sh"
run_stage "Skill contract validation" bash "$SCRIPT_DIR/validate-contracts.sh"
run_stage "SKILL.md ↔ agent cross-reference integrity" bash "$SCRIPT_DIR/validate-crossrefs.sh"
run_stage "next-issue->ship-issue hand-off ordering" bash "$SCRIPT_DIR/validate-next-issue-handoff.sh"
run_stage "Pre-scan empty/missing-input robustness" bash "$SCRIPT_DIR/validate-prescans.sh"
run_stage "pre-review-gates scan categories + skip policy" bash "$SCRIPT_DIR/validate-pre-review-gates.sh"
run_stage "codebase-audit issue-template sync" bash "$SCRIPT_DIR/validate-template-sync.sh"
run_stage "audit project-source integrity gate" bash "$SCRIPT_DIR/validate-audit-trust-gate.sh"
run_stage "shared scanner sync" bash "$SCRIPT_DIR/validate-shared-scanner-sync.sh"
run_stage "scanner test-file classification" bash "$SCRIPT_DIR/validate-scanner-classification.sh"
run_stage "check-ai-config detector fixtures" bash "$SCRIPT_DIR/validate-checker-detectors.sh"
run_stage "check-docs-* detector fixtures" bash "$SCRIPT_DIR/validate-docs-detectors.sh"
run_stage "check-security + check-code-health detector fixtures" bash "$SCRIPT_DIR/validate-source-detectors.sh"
run_stage "dev-core loop-* + drift-detect detector fixtures" bash "$SCRIPT_DIR/validate-loop-detectors.sh"
run_stage "golem-gate-watch feed snapshot" bash "$SCRIPT_DIR/golem-gate-watch.sh"
run_stage "Action pin format" bash "$SCRIPT_DIR/lint-action-pins.sh"
run_stage "Shell portability (bash 3.2 clean)" bash "$SCRIPT_DIR/lint-shell-portability.sh"
run_stage "Python-port contract + bash parity" bash "$SCRIPT_DIR/validate-python-ports.sh"
run_stage "Pre-scan bash<->python differential" bash "$SCRIPT_DIR/validate-prescan-differential.sh"
run_stage "Source-level category-slug parity" bash "$SCRIPT_DIR/validate-scanner-category-parity.sh"
run_stage "check-* deterministic coverage tool" bash "$SCRIPT_DIR/validate-patterns-coverage.sh"
run_stage "Shellcheck (bundled shell scripts)" bash "$SCRIPT_DIR/lint-shellcheck.sh"
run_stage "Python lint + format (ruff)" bash "$SCRIPT_DIR/lint-python.sh"
run_stage "Release toolchain coverage" bash "$SCRIPT_DIR/validate-release.sh"
run_stage "seed-worktree-trust path validation" bash "$SCRIPT_DIR/validate-seed-trust.sh"
run_stage "golem/worktree helper scripts" bash "$SCRIPT_DIR/validate-golem-scripts.sh"
run_stage "journal partial-recovery helper" bash "$SCRIPT_DIR/validate-recover-journal-partials.sh"
run_stage "workflow wall-time stop decision" bash "$SCRIPT_DIR/validate-workflow-wall-timeout.sh"
run_stage "autonomy-resolver decision table + parity" bash "$SCRIPT_DIR/validate-autonomy-resolve.sh"
run_stage "golem-notify Notification hook" bash "$SCRIPT_DIR/validate-golem-notify.sh"
run_stage "golem-resolve clearing-signal helper" bash "$SCRIPT_DIR/validate-golem-resolve.sh"
run_stage "golem-inbox brokered gate reverse channel" bash "$SCRIPT_DIR/validate-golem-inbox.sh"
run_stage "golem-watch streaming dispatcher" bash "$SCRIPT_DIR/validate-golem-watch.sh"

printf '\n========================================\n'
if [ "$rc" -eq 0 ]; then
    printf '  All test stages passed\n'
else
    printf '  One or more test stages FAILED\n'
fi
printf '========================================\n'

exit "$rc"
