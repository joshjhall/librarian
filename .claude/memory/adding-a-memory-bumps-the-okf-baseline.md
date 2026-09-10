---
name: adding-a-memory-bumps-the-okf-baseline
description: "Adding any file to .claude/memory/ raises an okf-bundle.baseline count; omitting the bump reds the 30-scanners shard on main and on every PR branched after it"
metadata:
  node_type: memory
  type: feedback
---

`tests/okf-bundle.baseline` freezes a per-category finding count for the memory
bundle, and `tests/validate-okf-bundle.sh` fails any category whose count rises
**above** its entry. Every file in `.claude/memory/` currently trips at least
`okf-missing-type` (the bundle nests `type:` under `metadata:` while OKF §4.1
wants it top-level — see #991). So **adding one memory file raises a count by
one**, and the bump belongs in the same commit.

**Why:** omitting it does not fail locally at commit time — it fails in the
`30-scanners` shard, which means main goes red and **stays** red for every PR
branched after that commit, not just for the author. Measured 2026-09-10: one
missing line in a memory commit (`6c2ad75`) blocked a golem's PR and cost about
an hour of orchestrator time, most of it spent misdiagnosing the push failures
it caused rather than the one-line omission.

**How to apply:** after writing a memory file and before committing, run

```bash
bash tests/validate-okf-bundle.sh > /tmp/okf.log 2>&1; echo $?
```

and raise whatever category it names, with the reason in the commit message —
the baseline's own header calls a raise "a deliberate, reviewable diff".

Three things that make this easy to get wrong:

- **The gate scans `git ls-files`, so an UNTRACKED new file is invisible to it.**
  Running it before `git add` exits 0 and tells you nothing — measured. Stage
  first, then run, or the check silently passes on the very file you added.
- **A second category can hide behind the first.** Fixing `okf-missing-type`
  surfaced `memory-missing-why` on the next run. Re-run until it exits 0; do not
  assume one bump is the whole fix.
- **Which category depends on the file's `type:`.** A `feedback` or `project`
  memory must carry `**Why:**` and `**How to apply:**` lines or it also trips
  `memory-missing-why`; adding those sections is better than bumping that count.
- **Do not "fix" the file by hoisting `type:` to the top level.** That would make
  it the single conformant file in a 240-file bundle and pre-empt the
  migrate-vs-document decision #991 exists to make. Raise the baseline instead.

The failure surfaces as a **push rejection whose notification says exit code 0** —
the suite verdict is in the redirected log, not the wrapper. See
[[background-task-exit-code-is-the-wrappers]]. Same ratchet idiom as
[[scratch-file-under-memory-fails-the-push]], which is the other way this
directory reds a push.
