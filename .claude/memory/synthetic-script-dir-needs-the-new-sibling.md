---
name: synthetic-script-dir-needs-the-new-sibling
description: Adding a sourced sibling breaks every test fixture that builds a synthetic SCRIPT_DIR by copying the script — update the fixture, not the assertion
metadata:
  type: project
---

A script that resolves dependencies from its own `SCRIPT_DIR` is often tested by
**shadow-dir fixtures**: copy the script to a temp dir beside a stubbed
dependency, and run the copy. Give that script a NEW sourced sibling and every
such fixture breaks at once — the copy loads nothing, and the failure surfaces as
the tested block rendering empty, not as "a dependency is missing."

Grep for the existing copy line before assuming a fixture is broken:
`grep -n 'cp .*config.sh' tests/...`. Wherever a dependency is already copied in,
the new sibling belongs on the next line.

**Why:** three fixtures in `tests/golem-scripts/85-context-budget.sh` failed this
way in #800 when `golem-status-signals.sh` was added. The distinction that
matters: this is a **fixture** consequence, not an assertion change. The issue's
AC said existing assertions must not need editing, and none did — `git diff` over
`tests/` showed zero removed or modified assertions. Rewriting an assertion to
accommodate the missing file would have silently weakened it.

**How to apply:** when adding a sourced fragment, grep the test tree for fixtures
that copy the parent script and add the sibling to each, with a comment saying
why. Then verify the diff over `tests/` contains no `-` line touching an
`assert_`. Related: [[test-defined-but-never-registered]].
