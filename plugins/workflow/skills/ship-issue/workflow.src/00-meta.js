export const meta = {
  name: 'next-issue-review',
  description:
    'Budgeted, resumable adversarial review for ship-issue: fans review dimensions (security/correctness/tests/conventions/decomposition/scope-drift) as one parallel barrier under a single budget, folds in open PR review comments (post-PR cycles), then in one fresh-judge pass re-scores each finding certainty AND characterizes its nature, from which an ordered rule list computes blocking-vs-deferrable for the skill to resolve-or-defer. On a re-review cycle (cycle > 1) with a caller-supplied fix-commit delta, narrows the delta-local dimensions to that delta while scope-drift keeps the full diff. One cycle per invocation — the skill owns the cycle loop and the cap.',
  phases: [
    { title: 'Manifest', detail: 'build + classify the changed-file manifest, decide specialists' },
    { title: 'Review', detail: 'review dimensions run as one parallel barrier under one budget' },
    { title: 'Comments', detail: 'fold open GitHub PR review comments into the finding stream (pr-cycle only)' },
    { title: 'Judge', detail: 'one fresh judge re-scores each finding certainty AND characterizes its nature; a rule list then computes blocking vs deferrable (no producer self-grading)' },
  ],
}

