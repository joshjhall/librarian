---
name: split-entry-point-drops-the-reporter
description: Rebuilding a suite's entry point from its run_test lines silently drops the trailing generate_report — the suite then FAILs while exiting 0
metadata:
  type: feedback
---

When splitting a test suite into the thin-entry-point + fragments shape, the
entry point is naturally rebuilt from the **`run_test` dispatch lines**. That
reconstruction drops whatever followed them — and what follows them is
`generate_report`, the only call that turns `TESTS_FAILED` into a non-zero exit
status.

The result is the worst kind of green: the suite still runs every test, still
prints `... FAIL` for the failing ones, and still **exits 0**. `run-all.sh`'s
`run_stage` keys purely on the exit status, so CI renders `[ok]`. Nothing about
the file looks incomplete in review — the tests are registered and they do run;
only the verdict is uncollected.

**Copy the ORIGINAL file's tail, don't regenerate it.** Diff the old tail against
the new one before committing:

```bash
git show HEAD:tests/<suite>.sh | tail -3
tail -3 tests/<suite>.sh
```

And prove the reconstructed suite can actually go red — mutate something it
covers and confirm a **non-zero exit**, not merely a FAIL line. A suite that
cannot fail is not a gate. Sweep the siblings while you are there:

```bash
for f in tests/*.sh; do
  grep -q 'lib/harness.sh' "$f" && ! grep -q 'generate_report' "$f" && echo "MISSING: $f"
done
```

This is the extraction analogue of [[test-defined-but-never-registered]]: there
the test never runs, here it runs and its failure never counts. It is why
[[diff-the-render-before-and-after-an-extraction]] and `split-verify` are both
required — split-verify checks that no *unit* was lost and passed this split
clean, because the dropped line is a top-level *call*, not a definition.

Filed as #899 (a lint asserting every harness-sourcing suite calls
`generate_report`).
