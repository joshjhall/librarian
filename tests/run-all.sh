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
#   6. Pre-scan empty/missing-input robustness (tests/validate-prescans.sh)
#   7. pre-review-gates scan categories + skip policy (tests/validate-pre-review-gates.sh)
#   8. codebase-audit issue-template sync (tests/validate-template-sync.sh)
#   8b. audit project-source integrity gate (tests/validate-audit-trust-gate.sh)
#   9. shared scanner sync (tests/validate-shared-scanner-sync.sh)
#   9b. scanner test-file classification (tests/validate-scanner-classification.sh)
#   9c. check-ai-config detector fixtures (tests/validate-checker-detectors.sh)
#  10. golem-gate-watch feed snapshot (tests/golem-gate-watch.sh)
#  11. Action pin format (tests/lint-action-pins.sh)
#  11b. Shell portability / bash-3.2 clean (tests/lint-shell-portability.sh)
#  11c. Python-port contract + bash parity (tests/validate-python-ports.sh)
#  11c2. Pre-scan bash<->python differential (tests/validate-prescan-differential.sh)
#  11c3. Source-level category-slug parity (tests/validate-scanner-category-parity.sh)
#  11d. Shellcheck — bundled shell scripts (tests/lint-shellcheck.sh)
#  11e. Python lint + format — ruff (tests/lint-python.sh)
#  12. Release toolchain coverage (tests/validate-release.sh)
#  13. seed-worktree-trust path validation (tests/validate-seed-trust.sh)
#  14. golem/worktree helper scripts (tests/validate-golem-scripts.sh)
#  14a2. journal partial-recovery helper (tests/validate-recover-journal-partials.sh)
#  14a3. workflow wall-time stop decision (tests/validate-workflow-wall-timeout.sh)
#  14b. autonomy-resolver decision table + parity (tests/validate-autonomy-resolve.sh)
#  14c. golem-notify Notification hook (tests/validate-golem-notify.sh)
#  14d. golem-watch streaming dispatcher (tests/validate-golem-watch.sh)
#
# Each stage is run to completion (no early exit) so a failure in one still
# lets the others report. Exits non-zero if any stage fails. No Docker; node +
# bash + coreutils only (jq is used opportunistically by the contract gate).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0

run_stage() {
    local label="$1"
    shift
    printf '\n========================================\n'
    printf '  %s\n' "$label"
    printf '========================================\n'
    if "$@"; then
        printf '[ok] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
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
run_stage "Pre-scan empty/missing-input robustness" bash "$SCRIPT_DIR/validate-prescans.sh"
run_stage "pre-review-gates scan categories + skip policy" bash "$SCRIPT_DIR/validate-pre-review-gates.sh"
run_stage "codebase-audit issue-template sync" bash "$SCRIPT_DIR/validate-template-sync.sh"
run_stage "audit project-source integrity gate" bash "$SCRIPT_DIR/validate-audit-trust-gate.sh"
run_stage "shared scanner sync" bash "$SCRIPT_DIR/validate-shared-scanner-sync.sh"
run_stage "scanner test-file classification" bash "$SCRIPT_DIR/validate-scanner-classification.sh"
run_stage "check-ai-config detector fixtures" bash "$SCRIPT_DIR/validate-checker-detectors.sh"
run_stage "golem-gate-watch feed snapshot" bash "$SCRIPT_DIR/golem-gate-watch.sh"
run_stage "Action pin format" bash "$SCRIPT_DIR/lint-action-pins.sh"
run_stage "Shell portability (bash 3.2 clean)" bash "$SCRIPT_DIR/lint-shell-portability.sh"
run_stage "Python-port contract + bash parity" bash "$SCRIPT_DIR/validate-python-ports.sh"
run_stage "Pre-scan bash<->python differential" bash "$SCRIPT_DIR/validate-prescan-differential.sh"
run_stage "Source-level category-slug parity" bash "$SCRIPT_DIR/validate-scanner-category-parity.sh"
run_stage "Shellcheck (bundled shell scripts)" bash "$SCRIPT_DIR/lint-shellcheck.sh"
run_stage "Python lint + format (ruff)" bash "$SCRIPT_DIR/lint-python.sh"
run_stage "Release toolchain coverage" bash "$SCRIPT_DIR/validate-release.sh"
run_stage "seed-worktree-trust path validation" bash "$SCRIPT_DIR/validate-seed-trust.sh"
run_stage "golem/worktree helper scripts" bash "$SCRIPT_DIR/validate-golem-scripts.sh"
run_stage "journal partial-recovery helper" bash "$SCRIPT_DIR/validate-recover-journal-partials.sh"
run_stage "workflow wall-time stop decision" bash "$SCRIPT_DIR/validate-workflow-wall-timeout.sh"
run_stage "autonomy-resolver decision table + parity" bash "$SCRIPT_DIR/validate-autonomy-resolve.sh"
run_stage "golem-notify Notification hook" bash "$SCRIPT_DIR/validate-golem-notify.sh"
run_stage "golem-watch streaming dispatcher" bash "$SCRIPT_DIR/validate-golem-watch.sh"

printf '\n========================================\n'
if [ "$rc" -eq 0 ]; then
    printf '  All test stages passed\n'
else
    printf '  One or more test stages FAILED\n'
fi
printf '========================================\n'

exit "$rc"
