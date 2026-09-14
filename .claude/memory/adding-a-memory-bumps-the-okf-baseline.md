---
name: adding-a-memory-bumps-the-okf-baseline
description: "A MALFORMED memory raises an okf-bundle.baseline count; omitting the bump reds the 30-scanners shard on main and on every PR branched after it — write the memory correctly instead of raising the number"
type: feedback
metadata:
  node_type: memory
---

`tests/okf-bundle.baseline` freezes a per-category finding count for the memory
bundle, and `tests/validate-okf-bundle.sh` fails any category whose count rises
**above** its entry — including a category the file does not list at all, which
carries an implicit baseline of **0**.

**A correctly-written memory now bumps nothing.** Until #991 the bundle nested
`type:` under `metadata:`, so every file tripped `okf-missing-type` and each new
one mechanically raised that count by one. #991 migrated the bundle to top-level
`type:` and the category left the baseline entirely. Write the frontmatter the
way [[okf-author]] specifies and the gate stays silent.

What survives is the failure mode, now reachable by a different route: a
`feedback` or `project` memory whose body omits the `**Why:**` /
`**How to apply:**` sections trips `memory-missing-why`, the one category still
carrying a baseline. **Fix the body rather than raising that number** — the count
is debt #631 is driving down, and raising it moves it the wrong way.

**Why:** omitting it does not fail locally at commit time — it fails in the
`30-scanners` shard, which means main goes red and **stays** red for every PR
branched after that commit, not just for the author. Measured 2026-09-10: one
missing line in a memory commit (`6c2ad75`) blocked a golem's PR and cost about
an hour of orchestrator time, most of it spent misdiagnosing the push failures
it caused rather than the one-line omission.

**How to apply:** **`bin/check-memory-baselines.sh` now enforces this at
pre-commit** (#1007) — lefthook runs it on any commit staging a file under
`.claude/memory/`, it materializes the staged tree with `git checkout-index`,
runs the real OKF gate against it, and names the category, the `N > M` delta,
and which of *your* staged files carries the row. It costs ~0.3s and it fails on
your machine, before the commit lands, rather than at someone else's push.

So the flow is: stage, commit, and read what the guard says. To check without
committing, run it directly:

```bash
git add -A .claude/memory
bash bin/check-memory-baselines.sh; echo $?
```

**Fix whatever it names.** Raising a baseline entry is the last resort, not the
first move: it is a deliberate, reviewable diff that wants a reason in the commit
message, and for `memory-missing-why` the fix is two lines of body text.

Five things that make this easy to get wrong:

- **The gate scans `git ls-files`, so an UNTRACKED new file is invisible to it.**
  Running it before `git add` exits 0 and tells you nothing — measured. Stage
  first, then run, or the check silently passes on the very file you added. (The
  pre-commit guard sidesteps this by materializing the index itself.)
- **Forgetting the `MEMORY.md` index line fails too, and is the likelier miss.**
  An unindexed memory trips `memory-orphan`, a category the baseline does not
  list at all — implicit 0, so a single one fails. It is easy to hit because the
  file itself is perfectly conformant; only its pointer is missing.
- **A second category can hide behind the first.** Fixing `okf-missing-type`
  surfaced `memory-missing-why` on the next run. Re-run until it exits 0; do not
  assume one fix is the whole fix.
- **Which category depends on the file's `type:`.** A `feedback` or `project`
  memory must carry `**Why:**` and `**How to apply:**` lines or it trips
  `memory-missing-why`; adding those sections is better than bumping that count.
- **`type:` goes at the TOP LEVEL, never under `metadata:`.** This is the shape
  the scanner reads (OKF §4.1) and the one [[okf-author]] specifies. Nesting it
  is silently tolerated as an unknown key — the memory simply reads as having no
  type, which is the defect #991 cleared across the whole bundle. A memory
  written in the old shape re-opens a category that no longer has a baseline
  line, so it fails as an unlisted category rather than as a raised count.

The failure surfaces as a **push rejection whose notification says exit code 0** —
the suite verdict is in the redirected log, not the wrapper. See
[[background-task-exit-code-is-the-wrappers]]. Same ratchet idiom as
[[scratch-file-under-memory-fails-the-push]], which is the other way this
directory reds a push.
