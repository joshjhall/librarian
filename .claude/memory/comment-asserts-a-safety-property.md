---
name: comment-asserts-a-safety-property
description: A comment that justifies omitting a guard by claiming a sibling already has it must be measured; the claim is the dangerous half
metadata:
  type: feedback
---

When a comment explains why one runtime needs a guard and its twin does not,
**measure the twin's claimed property before writing the sentence.** In
`check-security/patterns.py` the shebang read was capped at 512 bytes with:
"the bash half's `read` builtin stops at the first newline for the same reason."
True only when a newline exists — `read` stops at a newline **or EOF**, so a
20MB newline-free file was read whole (measured: 20,000,020 bytes into a shell
variable). The bash half had no cap at all.

**Why:** the missing cap was a bug; the comment was worse. It told the next
reader the property was already handled, so the place to look was pre-marked as
safe. A reviewer who trusts it never probes, and the gap survives every future
pass. This is [[comment-asserts-intent-not-code]] in its cross-runtime form: the
comment does not describe THIS code, it makes a claim about a SIBLING.

**How to apply:** any comment of the form "X is safe because Y already does Z"
is a testable assertion about Y — run it. Cheap here: one `read` against a
newline-free file. When the claim turns out false, fix the code AND rewrite the
comment to state what was measured, since the stale justification is what would
re-hide it. Related: [[parity-gate-hides-shared-defect]],
[[measure-suppression-before-keeping-it]].
