---
name: staged-tree-checks-need-checkout-index
description: "A pre-commit check that runs a repo gate must materialize the index with `git checkout-index` — `ls-files` reads the INDEX but scanners read CONTENT from the worktree, so a staged-broken/worktree-fixed file reports clean; and `--diff-filter=ACMR` silently drops the deletion route"
type: feedback
---

A pre-commit guard judges **what is about to be committed**, and neither half of
that comes for free from running an existing gate in the working directory.

**Two measured traps, both silent** (#1007, `bin/check-memory-baselines.sh`):

- **Index vs worktree are different trees.** `tests/validate-okf-bundle.sh`
  enumerates with `git ls-files` — which reads the **index**, so a staged-but-
  uncommitted file *is* visible — but the scanner then opens each path and reads
  its bytes from the **working tree**. Stage a file broken, fix it on disk, and
  the gate exits **0** while the commit carries the defect. Measured both ways.
  `git checkout-index -a --prefix="$tmp/"` materializes the real staged bytes;
  point the gate at that with its root env var.
- **`--diff-filter=ACMR` looks obviously right and is wrong.** The reasoning is
  "a deletion cannot raise a count". It can: deleting a memory without removing
  its `MEMORY.md` pointer leaves `memory-dangling-index`, an unlisted category
  whose implicit baseline is 0 — one is enough. With `ACMR` the guard exits 0 on
  exactly that commit. Drop the filter; let the gate decide what matters.

Materialize with **`-a`** (every tracked path), not just the changed ones:
graph-health findings are whole-corpus properties. `memory-orphan` asks whether a
file is reachable from the index and `memory-dangling-index` asks the converse —
neither is answerable from the diff alone, and a partial tree reports every
untouched file as an orphan.

**Why:** both failures are of the silence-reads-as-a-pass shape (#538/#571) —
the guard prints nothing, exits 0, and is indistinguishable from a clean run, so
the defect lands and reds main for whoever pushes next. A guard built to prevent
that class must not reintroduce it through its own plumbing.

**How to apply:** when a pre-commit check wraps a gate that walks a tree, ask two
questions before trusting it. *Which tree does it actually read?* — if the answer
is "the worktree", materialize the index. *Which diff statuses put a commit in
scope?* — write the deletion fixture, because that is the one the intuitive
filter drops. Pin both with tests whose mutants are the naive spellings: reverting
to a worktree scan, and restoring `--diff-filter=ACMR`, must each turn a named
case red. See [[adding-a-memory-bumps-the-okf-baseline]] for the failure this
guards, and [[asymmetric-mutation-reads-as-untested]] for why the passing
direction needs its own case.
