---
name: issue-491-fable-tail-merge
description: "#491 L3: merged ship-issue rescore+classify into one fresh-judge fable pass; review self-review found the AC-untestable orchestration gap"
metadata: 
  node_type: memory
  type: project
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T15:51:06.780Z
---

Issue #491 (L3, PR #514, MERGED — was [[auto-mode-blocks-self-merge]], human-merged 15:46Z).

**Change**: `ship-issue/workflow.js` `next-issue-review` harness ran TWO `fable`
tail agents per cycle over identical `rawFindings` — Rescore (`RESCORE_SCHEMA`)
then Classify (`CLASSIFY_SCHEMA`) — i.e. up to 6 fable passes/issue at
MAX_CYCLES=3. Merged into one `JUDGE_SCHEMA`/`judgePrompt`/`Judge` phase
returning `{ref, certainty, disposition, rationale}` per finding. Halves fable
tail cost; preserves no-producer-self-grading + partial-cycle (#270) invariant.

**Review-loop lessons (the harness reviewed its own change):**

- **Merged orchestration is AC-untestable inline.** The apply+partition loop
  sat past `validate-workflow-helpers.mjs`'s ORCH_BOUNDARY, so AC#4
  ("blocking/deferrable equivalent on a fixture set") had NO test. Fix = extract
  a PURE `applyJudgeVerdicts(rawFindings, judged, budgetExhausted)` helper
  (mirroring `computeClean`) → fixture-testable. Same pattern any time you merge
  post-await orchestration: pull the testable core into a module-scope pure fn.
- **Renaming an extracted helper breaks the test extractor.** `extractHelpers`
  pulls BY NAME; rescorePrompt→judgePrompt needs the name list updated or it
  throws. Same class as the phase()↔meta.phases lockstep lint.
- **Self-introduced comment drift is a real conventions finding.** Editing code
  left `rescore`/`classify` prose in module docblock, TAIL_FLOOR, refOf — the
  review flagged all three. Grep descriptive comments after a rename.
- **Merging two judge gates = a LOW-certainty security/defense-in-depth
  finding** (deferrable): one injected payload can now downgrade cert+disposition
  in one call vs fooling two. But the two were NEVER a cross-checking pair
  (classify already read rescore's output), so it's the intended cost tradeoff,
  not a regression. Documented inline at JUDGE_SCHEMA rather than filing a
  redundant follow-up.

**Mechanics**: 74-char conform header cap bit twice ([[conform-scope-enum]]);
worktree-guard ([[edits-landed-in-main-not-worktree]]) caught a Read/Edit of the
MAIN-checkout test path — always edit via `.worktrees/issue-491/`. Pre-push hook
runs full quality-gates (~2min) → background every push.
