// NEGATIVE FIXTURE — intentionally INCONSISTENT phase()/meta.phases sets.
//
// This file is NOT a real workflow. It exists solely so the
// `test_workflow_phase_guard_detects_mismatch` test in
// `tests/lint-skills-agents.sh` can prove the phase↔meta consistency detector
// (`workflow_phase_meta_mismatch`) actually fires — in BOTH directions:
//   1. `phase('Ghost')` is called in the body but absent from meta.phases
//      → "phase-not-in-meta: Ghost"
//   2. meta.phases has `{ title: 'Orphan' }` with no matching phase() call
//      → "meta-not-in-phase: Orphan"
//
// `meta` is otherwise a valid pure literal so this fixture isolates the phase
// mismatch from the meta pure-literal detector. DO NOT "fix" this file — it
// must stay inconsistent.
export const meta = {
  name: 'phase-mismatch-fixture',
  description: 'Fixture proving the phase↔meta consistency detector fires.',
  phases: [
    { title: 'Alpha', detail: 'matched on both sides' },
    { title: 'Orphan', detail: 'declared in meta, never called' },
  ],
}

phase('Alpha')
phase('Ghost')
log('this fixture never runs')
