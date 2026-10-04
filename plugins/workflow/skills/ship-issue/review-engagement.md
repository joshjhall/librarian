# Review engagement floor (#1111)

Companion to `adversarial-review-step.md` and `ci-review-protocol.md`. A review
dimension can **succeed and say nothing**: return `findings: []` from a lone
`StructuredOutput` call (~53 output tokens) having opened no file. Measured
across 250 reviewer runs, 54 (21%) did exactly that, 17 of them `security`, and
the harness counted every one clean. This is the success-side sibling of #846,
where a dimension *dies* and its null collapses into clean.

## The two detectors

The harness cannot measure engagement by itself. `agent()` returns only the
schema-validated object, and `budget.spent()` is pooled across the barrier. So
there are two detectors, and both report into one field.

| Detector | Where | Signal |
| --- | --- | --- |
| Evidence contract | `workflow.js` (`classifyEngagement`) | `findings: []` with an empty `checked`, or a code-reading dimension whose `checked` is all `diff-only` |
| Transcript measurement | `scripts/review-engagement.sh` | the run whose answer the harness kept made zero investigative tool calls, and the dimension produced no finding |

A dimension that `classifyEngagement` flags is re-dispatched **once on opus**
before it is reported. Only flagged dimensions are retried, so an engaged cycle
costs nothing extra.

## Which run is judged

A dimension the harness retried has two runs in the transcript. The script
judges the run whose answer the harness **kept**, and it decides that without
relying on run order. File-name order is effectively random, and the journal
can be absent.

- **One run:** that run.
- **`retry_succeeded: true`:** the opus run. The retry is the only `opus`
  dispatch, so the script identifies it by model, not by position.
- **`retry_attempted: true` but not succeeded:** the sonnet run. Its result
  stayed in place.
- **No retry signal** (an older harness): flagged only if **every** run made
  zero calls. An ambiguous case can never produce an unengaged verdict.
- **Retry signal, but the model filter selects no run** (usually because no
  run's model could be attributed and it reads `unknown`): the no-signal rule
  above, plus a stderr `WARNING` naming the dimension. An empty subset must
  not skip the dimension, or an unengaged kept retry would go unflagged
  (#1133).

## Which dimensions may be diff-only

`CODE_READING_DIMENSIONS` in `workflow.src/72-verdicts.js` (security,
correctness, tests) is the **one** list. These dimensions answer questions about
code that the diff hunks only partly show. `scope-drift` compares the diff
against the issue, and `decomposition` judges the pre-scan's size numbers, so
both are **legitimately diff-only**. Flagging them would retry them every cycle
and block convergence forever. The harness stamps the distinction as
`dimension_engagement.<dim>.requires_code_reading`, and the transcript detector
reads that flag rather than keeping its own copy of the list.

An empty `checked` is unengaged for **every** dimension, because the answer
names nothing it examined.

## Result fields

| Field | Set by | Meaning |
| --- | --- | --- |
| `checked` (per dimension, in the schema) | reviewer | each `{target, how}` it examined; `how` is `read`, `grep`, `ran`, or `diff-only` |
| `unengaged_dimensions` | both | dimensions that returned without reviewing; each is also in `dimensions_skipped` |
| `dimension_engagement.<dim>` | harness | `engagement`, `checked` count, raw `findings` count (before the judge), `retry_attempted` (selected for the opus re-dispatch), `retry_succeeded` (that re-dispatch ran and returned; `false` when skipped at the budget floor or nulled), `requires_code_reading` |
| `dimension_metrics.<dim>[]` | script | `{tool_calls, output_tokens, model}` per run in dispatch order (two entries after an opus retry) |
| `engagement_measured` | script | `false` when the transcript dir held no `review:*` agents, so nothing was measured |

A non-empty `unengaged_dimensions` forces `budget_exhausted: true` and
`clean: false`. It is **not** `no_review_signal`: an unengaged cycle is charged
against `REVIEW_MAX_CYCLES`, so a dimension that disengages every cycle
dead-ends visibly at the cap instead of looping uncounted.

## Convergence

`review-convergence.sh` reads `unengaged_dimensions` **from the result file**
(rule `C2b-unengaged`, directly under `C2-partial`). It does not rely on the
caller passing `--partial true`. A zero from a dimension that did not look is
not the zero that `C4-zero` treats as convergence.

## Running the measurement

Run it once per cycle, after the harness returns and before the convergence
check. `<transcript-dir>` is the "Transcript dir" line the Workflow tool result
prints. Substitute `<skill-base-dir>` per `next-issue/worktree-safe-recipes.md`
(#815):

```bash
<skill-base-dir>/../../scripts/review-engagement.sh "<transcript-dir>" "$cycle_result_json"
# -> measured=true|false  dimensions=N  unengaged=N
```

The script exits 2 and leaves the result untouched when the dir or result file
is unreadable. On `measured=false`, say so in the cycle report. That cycle's
engagement rests on the harness's evidence contract alone.
