# Where the `conventions` review coverage went

On-demand companion to `pre-ship-validation.md` (Step 3.5 item 6) and
`ci-review-protocol.md` (step c). Load this when you want to know why the
adversarial pre-PR review — the **Workflow tool** with `ship-issue/workflow.js`
(`ship-issue` Step 3.5 item 6) — fans **five** dimensions rather than six, or
when you are tempted to re-add a convention sweep to a reviewer prompt.

## What changed (#551)

`conventions` was one of six dimensions in the inline fan-out. It is gone. The
harness now fans **security, correctness, tests, decomposition, scope-drift**.

It was demoted, not deleted for being useless — it was the dimension whose work
the repo already does deterministically, on every PR, for free. Its inline
instructions asked it to flag "naming, file/module structure, banned patterns,
required patterns (full command paths in scripts, `--locked` pinned versions,
just-recipe usage, conventional-commit scopes)". Most of that list has a gate.

Measured cost on the #471/#472 run:

| Cycle | Turns | Bash calls | cache_read |
| ----- | ----- | ---------- | ---------- |
| 1     | 84    | —          | ~4.6M      |
| 2     | 139   | 63         | ~7.8M      |

Paid on **every cycle of every PR**. On the #557 baseline run the same reviewer
spent **164 of its 207 Bash calls** hand-measuring what the linters compute —
six consecutive `awk` one-liners re-deriving a line-length check, then re-running
`rumdl` and `shellcheck` itself.

## What still covers it, per PR, deterministically (AC#3)

These run in `tests/run-all.sh`, so they gate CI **and** the lefthook pre-push
hook. A PR cannot merge past them, which is what makes them a stronger gate than
an LLM reviewer's opinion — they are not advisory.

| Gate                             | Convention enforced                                          |
| -------------------------------- | ------------------------------------------------------------ |
| `lint-shellcheck.sh`             | shell correctness (`--severity=warning`) over `plugins/ tests/ bin/` |
| `lint-shell-portability.sh`      | bash-3.2 constructs + GNU-only regex (macOS BSD target)      |
| `lint-action-pins.sh`            | GitHub Actions SHA pin + version-comment agreement            |
| `lint-skills-agents.sh`          | flat `agents/<name>.md` layout, house values                  |
| `lint-command-refs.sh`           | namespaced `/<plugin>:<skill>` slash-command refs             |
| `lint-worktree-recipes.sh`       | worktree-safe recipe spelling                                 |
| `lint-workflow-js-generated.sh`  | generated artifacts fresh w.r.t. their fragments              |
| `lint-prose-budget.sh`           | per-type markdown size budgets, ratcheted                     |
| `lint-python.sh` / `ruff`        | Python style + format, version-pinned                         |
| `conform` (`.conform.yaml`)      | conventional-commit type and scope enum                       |
| `rumdl` / `typos` / `dprint`     | markdown, spelling, formatting                                |

## What moved to the scheduled audit

The judgment-shaped remainder — CLAUDE.md drift, cross-reference rot, skill and
agent quality — pairs with `check-ai-config` on a documented biweekly cadence.
**Read `review-audit`'s `codebase-audit/convention-cadence.md` for that,
including which half is actually enforced.** In brief (#907): the
**deterministic** half now runs on a schedule —
`.github/workflows/ai-config-prescan.yml` executes `check-ai-config`'s pre-scan
twice monthly as a ratchet against a checked-in baseline — while the
**LLM-judgment** half is still an operator ritual nothing triggers. Do not treat
this demotion as "coverage moved and is now guaranteed elsewhere". Half of it is
guaranteed; half of it is a checklist someone must pick up.

## What nothing covers now

Stated plainly rather than left to inference, because an unfalsifiable coverage
claim is worse than an admitted gap:

- **Ad-hoc prose conventions in `CLAUDE.md` that no linter models.** The gates
  above encode the rules someone bothered to automate. A convention that lives
  only as a sentence in `CLAUDE.md` — a naming preference, an architectural
  "prefer X over Y" — is now checked by nobody on a per-PR basis.
- **Cross-file consistency judgment against a live diff.** The demoted reviewer
  could notice that a new file diverged from the shape of its five siblings. The
  scheduled audit sees the tree, not the diff, and reports later.
- **Latency.** A violation the audit catches biweekly may already have been
  copied into several PRs — the issue's own open question, unresolved by design.
  The mitigation is that the demoted set is narrow: the automated majority still
  blocks per-PR.

## Two things that did NOT change

**`conventionsDigest` stays.** The digest (#557) is rendered by
`conventionsSection()` into `reviewerData()` — the shared prompt prefix **every**
surviving dimension reads, not the conventions reviewer's private input.
Removing it would degrade the other five and re-open the finding that reviewers
each re-read `CLAUDE.md`. Demoting the dimension and deleting the digest are
separate changes; only the first happened.

**The blocking-rule set is unchanged (AC#4).** No rule in `72-verdicts.js` is
keyed on `category === 'conventions'` — the only category-keyed rule is R3, which
reads `security`. `55-disposition-policy.js` needed no edit, and got none.

## If you are about to re-add a convention sweep

Don't, without measuring first. The cheap answer is almost always a new
`tests/lint-*.sh` gate: deterministic, free, blocking, and it runs on every PR
rather than on whichever ones a reviewer happens to look hard at. The expensive
answer is a sixth dimension, and it is the one this issue removed.
