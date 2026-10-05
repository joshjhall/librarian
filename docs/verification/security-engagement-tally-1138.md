# Security-dimension engagement: running tally (#1138)

**Status:** open. The baseline below was recorded before the fix. "After" rows are
added as ship-issue review cycles run on the fixed harness. The doc closes with a
verdict once there are enough rows to compare the two rates.

## What is measured

The rate at which ship-issue's `security` review dimension is **still unengaged
after the opus retry** (#1111). In those cycles, every `checked` entry it returns
is `how: "diff-only"`, so `unengaged_dimensions` contains `security` and the cycle
is reported partial. Each occurrence costs one extra full review cycle.

The source is the cycle-result JSON the harness returns, as saved by callers
under `~/.cache/librarian-review/<run>/<cycle>.json`. The fields used are
`dimension_engagement.<dim>.retry_attempted` and `unengaged_dimensions`. Only
results that carry `dimension_engagement` with `retry_attempted` count, which
means post-#1111 harness output.

## Cause found while fixing (not stated in the issue)

`reusedReviewerPrompt` told the reviewer to follow "the corresponding Sub-Reviewer
Definition in your instructions". Since #494/#524, those definitions live only in
the code-review harness's `SUBREVIEWERS` map, and only that harness pastes them.
ship-issue's security reviewer therefore received **no checklist at all**.
correctness has the same dangling reference, but bug-hunting is the model's
default behaviour, so it engages anyway. That is why security was the only
dimension the retry could not recover.

The fix has two parts:

- security gets inline must-read instructions with concrete questions
  (`workflow.src/30-dimensions.js`, `SECURITY_INSTRUCTIONS`), placed at the
  prompt tail;
- the opus retry now appends `retryNotice(...)`, which names the rejected answer's
  shape (`workflow.src/70-prompts.js`).

## Recipe

```bash
cd ~/.cache/librarian-review
for f in $(grep -rl --include='*.json' dimension_engagement . | sort); do
  python3 - "$f" <<'EOF'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); r = d.get('result', d)
if not isinstance(r, dict): sys.exit()
de = r.get('dimension_engagement') or {}
if not any('retry_attempted' in v for v in de.values()): sys.exit()
retried = [k for k, v in de.items() if v.get('retry_attempted')]
print(f, 'retried=', retried, 'unengaged=', r.get('unengaged_dimensions'))
EOF
done
```

## Baseline: before #1138 (2026-10-04)

There are 21 post-#1111 cycle results across runs golem-1120, golem-1133,
issue-1111, solo, solo-1115, solo-1128, and solo-1129.

| Dimension   | Cycles retried | Still unengaged after the opus retry |
| ----------- | -------------- | ------------------------------------ |
| security    | 8              | **4** (50%)                          |
| correctness | 10             | 0                                    |
| tests       | 4              | 0                                    |

The four security misses were golem-1120/cycle1, solo-1128/cycle2, solo-1128/pr1,
and solo/pr-cycle1. In every one of them, all 4–6 `checked` entries were
`diff-only`.

## After: rows (add one per cycle on the fixed harness)

| Date | Run / cycle | Security retried? | Security unengaged after retry? | First-pass `how` mix |
| ---- | ----------- | ----------------- | ------------------------------- | -------------------- |
| 2026-10-04 | solo-1138/c1 (this PR, pre-pr) | no | no | 4 read, 2 diff-only |
| 2026-10-04 | solo-1138/c2 (this PR, pre-pr) | no | no | 2 read, 4 diff-only |

Neither cycle's conventions digest told security to Read anything. Before #1138, a hand-written
digest instruction like that was the only thing that recovered security (#1138's issue body).

**Verdict criterion:** the fix holds if security's unengaged-after-retry count is
0 over at least 10 cycles on the fixed harness, and if its first-pass retry rate
falls below the 8/21 baseline.
