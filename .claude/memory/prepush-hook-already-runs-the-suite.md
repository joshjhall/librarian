---
name: prepush-hook-already-runs-the-suite
description: "Don't run tests/run-all.sh by hand before pushing — lefthook's pre-push quality-gates step runs that exact command; budget the push instead"
metadata:
  node_type: memory
  type: feedback
---

`lefthook.yml`'s **pre-push** `quality-gates` step is literally
`run: bash tests/run-all.sh`, globbed to `plugins/**`, `tests/**`, and
`.github/workflows/**`. Nearly all work in this repo touches one of those, so a
push runs the full suite whether or not it was already run by hand.

**Why:** running it locally first and then pushing pays the same ~5–9 min twice
on the same tree. It is not a safety net either — the hook runs *after* the
manual run, so if the manual run passed and the hook fails, the hook is what
stops the push regardless. Measured on the v4.37.9 codeql pin (a one-line SHA
swap): ~300 s local `run-all.sh` + 516 s pre-push hook, and no test in that
suite exercises a workflow `uses:` line. The local half bought nothing.

**How to apply:** push and let the hook be the full-suite run, with a 600 s
timeout ([[push-hang-is-the-prepush-suite]]). Locally, run only the *targeted*
gate for what changed when it is cheap and relevant — e.g.
`tests/lint-action-pins.sh` (2 s) for a pinned `uses:`, plus a mutation check
that the gate has teeth ([[mutation-round-finds-the-untested-rule]]). Run the
whole suite by hand only when actively iterating on a failure, or when a late
failure would be expensive (mid-release, before a tag).

The same doubling applies to `just lint`: pre-push already runs `typos`,
`dprint-check`, and `taplo-check`, and pre-commit runs the per-language linters
on staged files.
