#!/usr/bin/env bash
# Single entry point for the librarian test suite.
#
# Runs, in order:
#   1. Manifest validation (node tests/validate-manifests.mjs)
#   2. Skill/agent structural lint (tests/lint-skills-agents.sh)
#   3. Skill contract validation (tests/validate-contracts.sh)
#   4. SKILL.md ↔ agent cross-reference integrity (tests/validate-crossrefs.sh)
#   5. Pre-scan empty/missing-input robustness (tests/validate-prescans.sh)
#   6. golem-gate-watch feed snapshot (tests/golem-gate-watch.sh)
#   7. Action pin format (tests/lint-action-pins.sh)
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
else
    printf '[skip] Manifest validation — node not available\n'
fi

run_stage "Skill/agent structural lint" bash "$SCRIPT_DIR/lint-skills-agents.sh"
run_stage "Skill contract validation" bash "$SCRIPT_DIR/validate-contracts.sh"
run_stage "SKILL.md ↔ agent cross-reference integrity" bash "$SCRIPT_DIR/validate-crossrefs.sh"
run_stage "Pre-scan empty/missing-input robustness" bash "$SCRIPT_DIR/validate-prescans.sh"
run_stage "golem-gate-watch feed snapshot" bash "$SCRIPT_DIR/golem-gate-watch.sh"
run_stage "Action pin format" bash "$SCRIPT_DIR/lint-action-pins.sh"

printf '\n========================================\n'
if [ "$rc" -eq 0 ]; then
    printf '  All test stages passed\n'
else
    printf '  One or more test stages FAILED\n'
fi
printf '========================================\n'

exit "$rc"
