---
name: mutation-harness-keyed-on-exit-code
description: A mutation round keyed on the suite's EXIT CODE reports every rule "survived" when the suite exits 0 despite failing — suspect the harness, not the rules
metadata:
  type: feedback
---

When a mutation round reports that **every** rule survived, the harness is
broken — not the rules. Independent detectors are not all untested at once; that
result is a measurement artifact and should be investigated before it is
believed.

The specific trap: keying the round on the suite's **exit code**
(`if bash suite.sh; then echo SURVIVED`). A suite can print `... FAIL` lines and
still exit 0 — in this repo that happens whenever the entry point never calls
`generate_report`, which is the only thing that turns `TESTS_FAILED` into a
non-zero status. The mutation lands, the assertion genuinely fails, and the
harness records a pass.

**Key the round on the FAIL COUNT instead**, which is what you actually mean:

```bash
n=$(bash tests/<suite>.sh 2>&1 | grep -c 'FAIL' || true)
[ "$n" -eq 0 ] && echo "SURVIVED (untested)" || echo "killed ($n)"
```

Two corollaries, both cost real time here (#707):

1. **Verify one mutation by hand first.** Apply it, confirm the scanner's output
   actually changed, and confirm the suite reports a failure. That single probe
   distinguishes "rule untested" from "harness blind" in seconds.
2. **Never take the restore snapshot from a file you have already mutated, and
   never run two rounds concurrently on one file.** Overlapping rounds left
   sentinels in the "clean" snapshot, which re-infected every later restore and
   produced failures attributed to the wrong rule. Snapshot from a
   verified-clean file, and after the round assert zero sentinels remain — see
   [[mutation-restore-must-not-be-git-checkout]] for the complementary rule.

Related: [[mutation-round-finds-the-untested-rule]] (mutate every RULE, not every
test), [[strictness-first-fails-in-the-checker]] (a finer gate's first findings
are its own bugs).
