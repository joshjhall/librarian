// NEGATIVE FIXTURE — intentionally references a NONEXISTENT agentType.
//
// This file is NOT a real workflow. It exists solely so the
// `test_workflow_agenttype_guard_detects_dangling` test in
// `tests/lint-skills-agents.sh` can prove the agentType cross-ref detector
// (`workflow_dangling_agenttypes`) actually fires. The `agentType` below does
// not resolve to any `plugins/*/agents/<name>.md`, which at runtime would make
// the harness invoke a nonexistent agent.
//
// `meta` and the phase set are consistent so this fixture isolates the dangling
// agentType from the other detectors. DO NOT "fix" this file — the agentType
// must stay dangling.
export const meta = {
  name: 'dangling-agenttype-fixture',
  description: 'Fixture proving the agentType cross-ref detector fires.',
  phases: [{ title: 'Run', detail: 'single phase' }],
}

phase('Run')
await agent('do something', { agentType: 'nonexistent-agent' })
