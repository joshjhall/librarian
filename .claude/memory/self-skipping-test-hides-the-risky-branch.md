---
name: self-skipping-test-hides-the-risky-branch
description: "A test that skips itself when a tool is absent never covers the absent-tool branch — CI always has the tool, so the risky arm is the one arm tested nowhere"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d282d6e2-265f-4046-adc3-50e27ce0b45a
  modified: 2026-08-10T22:28:46.539Z
---

A test guarded by `if ! command -v X; then skip_test; fi` covers the
**X-is-present** branch only. If the code's other branch is the fallback *for
hosts without X*, that fallback is exercised **nowhere** — CI always has X, so
the skip never fires there, and the arm that only runs on the under-tested host
is the arm with zero coverage.

Issue #543 was exactly this: `test_hanging_uvx_is_bounded_not_wedged` skipped itself
when `timeout` was absent, so the unbounded fallback — the one that ran on base
macOS — was never tested. It **passed against the buggy code**, which is why the
bug survived.

**Why:** the skip reads as prudence ("can't test what isn't here") but inverts
the risk. You skip on the hosts that need the coverage and run on the host that
doesn't.

**How to apply:** don't skip on tool absence — **force** it. Build a stub PATH
that is the entire PATH and deliberately omit the tool, then assert the fallback
behaves. Two traps that silently invalidate this, both hit in one session:

- `BASH_ENV` (devcontainers set it) re-sources a profile that **resets PATH**, so
  the real tool leaks back in. Scrub it: `env -u BASH_ENV`.
- The stub PATH must carry everything the code-under-test needs (`grep`, `awk`,
  `sleep`, `kill`, …) or it fails for an unrelated reason that looks like a pass
  of the wrong thing. Add an explicit assertion that the tool is genuinely absent
  and the deps are genuinely present — the sandbox's validity is itself a claim
  that needs checking.

Then mutation-test: restore the old code and confirm the new test **fails**.
Related: [[mutate-every-rule-not-every-test]], [[test-defined-but-never-registered]].
