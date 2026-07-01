// NEGATIVE FIXTURE — intentionally references a BARE (un-namespaced) agentType.
//
// This file is NOT a real workflow. It exists solely so the
// `test_workflow_agenttype_guard_detects_bare` test in
// `tests/lint-skills-agents.sh` can prove the agentType cross-ref detector
// (`workflow_dangling_agenttypes`) flags a bare name even though its basename
// resolves (`plugins/dev-core/agents/code-reviewer.md` DOES exist).
//
// This is the exact issue #126 bug class: the Agent tool's `subagent_type`
// takes the bare name, but the Workflow tool's agent() resolver keys agents
// only by their namespaced `<plugin>:<name>` form — so a bare `code-reviewer`
// passes a basename check yet throws at runtime. The correct value here would
// be `dev-core:code-reviewer`.
//
// `meta` and the phase set are consistent so this fixture isolates the bare
// agentType from the other detectors. DO NOT "fix" this file — the agentType
// must stay bare.
export const meta = {
  name: 'bare-agenttype-fixture',
  description: 'Fixture proving the agentType detector flags a bare name.',
  phases: [{ title: 'Run', detail: 'single phase' }],
}

phase('Run')
await agent('do something', { agentType: 'code-reviewer' })
