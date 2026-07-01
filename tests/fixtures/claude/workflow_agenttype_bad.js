// NEGATIVE FIXTURE — intentionally references a NAMESPACED-but-UNRESOLVABLE
// agentType.
//
// This file is NOT a real workflow. It exists solely so the
// `test_workflow_agenttype_guard_detects_dangling` test in
// `tests/lint-skills-agents.sh` can prove the agentType cross-ref detector
// (`workflow_dangling_agenttypes`) fires on a well-formed `<plugin>:<name>`
// ref whose agent file does not exist. `workflow:nonexistent-agent` has no
// `plugins/workflow/agents/nonexistent-agent.md`, which at runtime would make
// the Workflow tool's agent() resolver throw.
//
// `meta` and the phase set are consistent so this fixture isolates the dangling
// agentType from the other detectors. DO NOT "fix" this file — the agentType
// must stay unresolvable.
export const meta = {
  name: 'dangling-agenttype-fixture',
  description: 'Fixture proving the agentType cross-ref detector fires.',
  phases: [{ title: 'Run', detail: 'single phase' }],
}

phase('Run')
await agent('do something', { agentType: 'workflow:nonexistent-agent' })
