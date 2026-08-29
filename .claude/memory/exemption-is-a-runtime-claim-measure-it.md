---
name: exemption-is-a-runtime-claim-measure-it
description: "An exemption/boundary claim states runtime behavior — run the one command that checks it, because the exemption is what stops anyone looking again"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2dc81361-1df4-44f7-8439-b972dcba2f8f
  modified: 2026-08-27T00:53:30.204Z
---

Whenever you exempt a site from a gate, or write "this one is different because
X", you are asserting **runtime behavior**. Run the command that checks it. The
cost is one invocation; the cost of being wrong is permanent, because an
exemption is precisely the thing that stops the gate — and the next reader —
from ever looking again.

**Why:** in one change (#815, fixing #809's false "only one recipe" note) three
of my own boundary claims were proven wrong under review, each the same reflex
the issue existed to correct:

1. "No shell variables at all" — actually static *evaluability*; inline-assigned
   vars and unbraced `$HOME` pass.
2. "Exactly three inline directives, all naming `autonomy-resolve.sh`" — two
   other scripts had them. A hand-kept census in prose rots into false
   confidence.
3. "Detached-golem feed path, never worktree-isolated" — measured false in one
   command. The error was confusing a subsystem's **reader** with its **writer**:
   the orchestrator reads the feed from the main checkout, but the golem that
   *emits* the event is isolated, and a solo run has no orchestrator at all.

Claim 3 was the worst: the issue's own evidence table already named one of the
lines I exempted.

**How to apply:**

- Ask **"which ACTOR runs this?"**, never "which subsystem does this belong to?"
  A script's name says nothing about the session that invokes it.
- Prefer a **measured ratchet** over a prose count. A hand-maintained number is a
  claim a reader must trust; a re-derived one fails loudly when stale. See
  [[stale-artifact-makes-the-stub-pass]].
- A ratchet needs a **floor as well as a ceiling**. The ceiling catches the
  corpus growing; only the floor catches the *pattern breaking* — verified by a
  mutation that survived a ceiling-only check and died against the floor.
- A reason-required exemption marker is a **soft control**: any plausible
  sentence satisfies it. Bound the exemption *population* so each addition is a
  diff a human weighs. Related: [[comment-asserts-intent-not-code]],
  [[measure-suppression-before-keeping-it]].
