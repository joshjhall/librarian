---
name: skip-guard-may-outlive-its-dependency
description: A `command -v X` skip guard can outlive the dependency it guards — widening it preserves a dependency that is already gone; A/B the guard against its SUBJECT before fixing it
metadata:
  type: feedback
---

A tool-presence skip guard (`command -v timeout` → `skip_test`) names a
dependency of the code **as it was written**. When the subject is later
rewritten to drop that dependency, the guard is not updated — nothing fails,
because a skip is silent. The guard then reports "cannot test this here" about
a test that would pass fine.

**Why:** the guard *is* the reason nobody notices. The case skips on the author's
host, so the coverage it claims to need is never observed to be unnecessary — and
it hides real failures. A skip on a developer's Mac concealed a hard CI failure
(`bounded_run: command not found`) for a whole round trip. This is worse than a
stale comment, because a comment cannot suppress the test that would contradict
it.

**The trap when fixing it.** The obvious remedy — "the guard is too narrow, also
accept `gtimeout`" — is a plausible reading that can be *wrong*, and it fails
silently in the same direction: it re-asserts a dependency that no longer exists
and leaves any vacuous `test_tool_available` prerequisite passing. A guard's text
tells you what someone once believed; only the subject tells you what is true
now.

**How to apply:** before widening or copying a skip guard, A/B it against its
subject. Build a PATH stub holding every system executable *except* the guarded
tool, neuter the guard's condition (`guard() { false; }`), and run the suite
under `PATH=<stub> env -u BASH_ENV`. If the previously-skipped cases **pass**,
the guard is stale — delete it, and delete any test that asserts only the
guard's own premise. If they fail, it is genuinely narrow; prefer converting the
subject to a dependency-free bound over teaching the guard a second tool name.
Class each site by its subject; a single sweep across "18 identical guards" will
contain both kinds.

Measured on #960: `validate-golem-watch.sh` gated its whole suite on
`command -v timeout` while bounding via `bounded_run`; with no `timeout`
anywhere on PATH all four real cases passed and only the self-referential
prerequisite failed. Two `golem-scripts` guards proved stale the same way —
their helper's own comment already said the guard "never protected this helper".

Related: [[detector-must-fail-open-on-its-own-failure]],
[[measure-suppression-before-keeping-it]],
[[comment-asserts-intent-not-code]], [[exemption-is-a-runtime-claim-measure-it]]
