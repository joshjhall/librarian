---
name: harden-one-knob-grep-every-sibling
description: "Hardening one call site while leaving its siblings exposed is my recurring self-inflicted bug class — after fixing X, grep for every sibling that reaches the same construct (#487, #489, #493)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b3100c69-fe8e-4fa0-9335-e1a0ad5da29c
  modified: 2026-08-01T04:18:18.290Z
---

Three separate PRs caught the same shape: I fixed or changed **one** call site
and left an identical sibling exposed, or changed a behavior the original
position was quietly providing. The adversarial pre-PR review caught all three;
none were caught by my own tests.

**#489 (PR #509) — hardened one knob, opened the same hole in its sibling.**
I added `since_summary=$((since_summary + heartbeat_interval))`. Under
`set -uo pipefail`, a non-numeric `GOLEM_HEARTBEAT_INTERVAL` (a plausible typo
like `15m`) makes bash treat the alphabetic token as an unbound variable inside
`$(( ))` and **aborts the whole watch**. I had already guarded the *sibling*
knob but left the one I newly consumed in arithmetic exposed. Fix = coerce at
the assignment: `case "$v" in '' | *[!0-9]*) v=60 ;; esac`.
**Any NEW `$(( ))` use of an env-sourced var under `set -u` is a crash vector.**

**#487 (PR #496) — tested one splice site, shipped an injection at the other.**
A `--model` fragment is spliced into a double-quoted word that tmux runs via
`sh -c`. My `print`-only tests missed the real `launch` dispatch argv, an
independent second splice site where a raw value like `x"; touch pwned; echo "`
breaks out and executes (verified PoC). Fix = backslash-escape the 4 chars
special in a POSIX double-quoted word — backslash FIRST, then double-quote,
backtick, dollar. NOT an allow-list: legitimate bracketed ids like
`claude-opus-4-8[1m]` would be rejected, and brackets aren't double-quote-special
so they pass through untouched. I wrongly pre-dismissed this before the review
returned; the review was right.

**#493 (PR #534) — a "hoist out of the loop" silently changed two behaviors.**
The issue literally proposed hoisting a classify agent above a retry loop. Doing
exactly that broke two things the in-loop position was providing: (1) a null
classify short-circuited to zero fix attempts instead of retrying — `agent()` is
NOT deterministic, so "deterministic on static logs" was wrong reasoning; and
(2) the hoisted call ran BEFORE the `BUDGET_FLOOR` guard, firing an
un-budget-gated call per check. Fix = **memoize in-loop**
(`if (!memo) memo = await ...`), the minimal behavior-equivalent change.

**How to apply:**

- After fixing a construct, `grep` for every other site reaching it — then fix
  or explicitly test each. "I hardened the one I touched" is the bug.
- When an issue says "hoist X out of a loop," first ask what the in-loop
  position was giving X: retry semantics, budget/rate gating, per-attempt
  labels. Prefer memoize-in-loop when any must be preserved.
- Test the **real dispatch path**, not just the `print`/dry-run rendering of it.
- Extract the decision as a pure helper (`needsClassify(cls){return !cls}`) so
  the crux is unit-testable despite the sandbox — see
  [[test-workflow-js-pure-helpers]], [[two-runtime-model]].

Related: [[mutate-after-every-security-fixture]],
[[comment-asserts-intent-not-code]], [[ship-review-diff-must-be-faithful]].
