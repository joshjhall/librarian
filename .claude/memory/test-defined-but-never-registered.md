---
name: test-defined-but-never-registered
description: "A test function with no `run_test` line silently never runs while the suite reports green (#596)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e27f9ded-9f74-48fe-ba56-da0a45c3cf33
  modified: 2026-07-31T23:53:10.797Z
---

In the `tests/lib/harness.sh` suites, defining `test_foo()` does nothing on its
own — it runs only via an explicit `run_test test_foo "..."` dispatch line. Forget
that line and the test **silently never runs**, while the summary still prints all
green.

That is strictly worse than a missing test: the green count asserts coverage that
does not exist. In #596 a `--prev-result` malformed-JSON test sat unregistered and
the total stayed put at 48 — noticed only because I compared the expected count.

**How to apply:** add a self-check to any suite with a long dispatch list, and
compare NAME SETS, not counts — a bare count is defeated by two cancelling errors
(one test registered twice, another omitted):

```bash
check_every_test_is_registered() {
    defined="$(command grep -o '^test_[a-z_]*() {' "$0" | command sed 's/() {$//' | command sort -u)"
    registered="$(command grep -o '^run_test test_[a-z_]*' "$0" | command sed 's/^run_test //' | command sort -u)"
    # comm -23 = defined-but-unregistered; comm -13 = dispatched-but-undefined
}
```

Name the guard OUTSIDE the `test_*` namespace so it need not count itself. Verify
it non-tautologically by deleting one `run_test` line and watching it fail.

Same family as [[collect-all-test-assertions-must-not-throw]]: the failure mode is
a suite that reports success while quietly doing less than it claims.
