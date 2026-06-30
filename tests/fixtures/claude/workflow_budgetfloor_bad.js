// NEGATIVE FIXTURE — intentionally declares a NON-HOUSE BUDGET_FLOOR value.
//
// This file is NOT a real workflow. It exists solely so the
// `test_workflow_budget_floor_guard_detects_drift` test in
// `tests/lint-skills-agents.sh` can prove the BUDGET_FLOOR consistency detector
// (`workflow_budget_floor_value`) actually fires. The floor below is 99_000,
// which disagrees with the house value (40_000) every real harness must use, so
// a budget-floor tuning change would silently diverge here.
//
// `meta` and the phase set are consistent so this fixture isolates the floor
// drift from the other detectors. DO NOT "fix" this value — it must stay
// non-house so the guard has something to catch.
export const meta = {
  name: 'budget-floor-drift-fixture',
  description: 'Fixture proving the BUDGET_FLOOR consistency detector fires.',
  phases: [{ title: 'Run', detail: 'single phase' }],
}

const BUDGET_FLOOR = 99_000

phase('Run')
if (budget.total && budget.remaining() < BUDGET_FLOOR) {
  log('budget floor reached')
}
