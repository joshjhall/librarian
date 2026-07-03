---
name: model-tier-fable-valid
description: "fable is a valid agent model: tier; aliases auto-track latest generation, so \"sonnet\" agents already = Sonnet 5"
metadata:
  node_type: memory
  type: reference
  originSessionId: 23a4ebd0-030d-40b7-bdf5-8c16948ecd2f
---

Per official Claude Code docs (code.claude.com `sub-agents.md`, `model-config.md`),
the agent `model:` frontmatter accepts `fable` as a tier alias alongside
`haiku`/`sonnet`/`opus`/`inherit` and full model IDs (e.g. `claude-opus-4-8`).
The same tokens are valid in the Workflow tool's `agent()` `opts.model` and the
Agent/Task tool's model param.

**Tier aliases auto-track the latest generation**: `sonnet`→Sonnet 5,
`opus`→Opus 4.8, `fable`→Fable 5. So a "global sonnet bump" for new models is a
no-op at the token level — agents on `sonnet` already resolve to Sonnet 5. Only
pin a full model ID to deliberately freeze a generation.

Two repo gates hard-reject unknown model tokens and must be widened together
when adding a tier: `tests/lint-skills-agents.sh` (`VALID_MODELS`) and
`plugins/review-audit/skills/check-ai-config/patterns.sh` (the `check_agent_frontmatter`
model check + its message; also the `contract.md` suggestion string). Done in
PR #156 (issue #155): added `fable` + `inherit` to both.

Lineup intent: haiku=mechanical · sonnet=balanced default · opus=implementation/
most reasoning · fable=deep reasoning where errors are expensive (security
audits, review verification, orchestration — priciest, reserve it). In this repo
`audit-security` + `audit-architecture` are on fable; the adversarial
verify/rescore/classify workflow.js stages escalate to `model:'fable'` per-call.
