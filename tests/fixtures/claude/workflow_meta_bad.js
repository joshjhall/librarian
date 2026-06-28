// NEGATIVE FIXTURE — intentionally INVALID workflow.js meta block.
//
// This file is NOT a real workflow. It exists solely so the
// `test_workflow_meta_guard_detects_violations` test in
// `tests/lint-skills-agents.sh` can prove the meta pure-literal
// detector actually fires. Its `meta` block deliberately contains BOTH of the
// violations the guard must catch:
//   1. string concatenation in `description` ('Foo' + 'Bar')
//   2. template interpolation in `name` (${VAR})
//
// The Workflow tool would reject this at load time with "meta must be a pure
// literal". DO NOT "fix" this file — it must stay broken.
const VAR = 'find-flaky'
export const meta = {
  name: `${VAR}-tests`,
  description: 'Find flaky tests ' + 'and propose fixes',
  phases: [{ title: 'Scan', detail: 'grep logs' }],
}

phase('Scan')
log('this fixture never runs')
