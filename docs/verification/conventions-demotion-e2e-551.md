# #551 — live fan-out evidence: five dimensions, digest intact

**Status:** VERIFIED — live. Captured 2026-09-04 during the `/workflow:ship-issue`
run that shipped #551 itself, from the pre-PR review harness invoked on this
change's own committed diff.

This is the one check that could not be made from tests: the suite pins
`selectReviewDimensions` as a pure function, but not that a real harness
invocation actually dispatches five agents and still hands them the conventions
digest. The ship harness for this very PR is that observation.

## What was observed

Run ID `wf_68fb5bf8-d90`, phase `pre-pr`, cycle 1, 13 files.

Agents started, from `journal.jsonl` (6 total = 1 manifest + 5 dimensions):

```text
agent-aa590a7f52c7eb02a  Mode: manifest
agent-a87baacb7bdc198c9  reviewer:security
agent-a778ac762b2f296ef  reviewer:bug            (surfaced as category=correctness)
agent-a4dc7ecec4f16cdaf  test-coverage reviewer
agent-a2a092a6752faddf6  decomposition reviewer
agent-aca54e8bdac3374fb  scope-drift reviewer
```

**No `conventions` reviewer was dispatched.** Before this change the same
invocation would have started seven agents, the seventh being the
project-conventions reviewer.

## The digest survived (the AC#4-adjacent property)

```console
$ grep -l "PROJECT CONVENTIONS" agent-*.jsonl | wc -l
5
```

All five reviewer prompts carry the `PROJECT CONVENTIONS` data block. This is
the property most at risk of being broken by a careless version of this change:
`conventionsDigest` renders into `reviewerData()`, the prompt prefix **every**
dimension reads, so deleting it alongside the dimension would silently degrade
the five survivors and re-open #557. It did not.

## Why this file exists

`docs/verification/` holds evidence for claims a test cannot make. The pure
selector is unit-tested (`tests/workflow-helpers/ship-issue/03-narrowing-selector.mjs`,
including a mutation round). What no test could show is that the *deployed*
artifact, loaded by the real Workflow engine, fans exactly five ways — the
generated-artifact staleness class (#806) is precisely the failure where the
fragments are right and the shipped bytes are not. Here they agreed.
