---
name: issue-cause-may-be-falsified-by-measurement
description: An issue's stated cause and suggested fix are hypotheses — reproduce before implementing, or you ship a no-op
metadata:
  type: feedback
---

An issue body's **Cause** and **Suggested fix** sections are hypotheses written
by someone who had less evidence than you will have. Reproduce the failure and
A/B the proposed fix **before** implementing it, or you ship a green, useless PR
against a still-broken system.

Issue #766 asserted npm 11 gated agnix's `postinstall` so the binary never
installed, and suggested `npm install -g --allow-scripts=agnix`. Measured on the same
npm/node majors CI runs: the warning is emitted but **the postinstall runs and
the binary lands**, and the suggested flag changes nothing — not even the
warning. The real cause was that `npm install -g <local-dir>` **symlinks**, and
the step's own trailing `rm -rf "$verify_dir"` dangled the link.

**Why:** a plausible cause survives review easily — reviewers read the issue too,
and a fix matching the issue's story looks correct. Only a reproduction
distinguishes the stated cause from the real one.

**How to apply:**

- Reproduce the failure, then A/B the *suggested* fix specifically. If it changes
  nothing, the stated cause is wrong — stop and re-derive.
- Hunt for evidence the stated cause **cannot explain**. Here it was decisive: a
  CI run where the install step *succeeded* (no failure notice) and the gate
  still reported the tool absent. An install-failed theory predicts that notice.
- Distinguish the *warning* from the *failure*. A loud advisory beside a broken
  thing attracts the diagnosis; ask whether silencing it would fix anything.
- Say plainly in the commit, PR, and verification doc that the stated cause was
  falsified — otherwise the wrong cause survives in the tracker and misleads the
  next person. Related: [[comment-asserts-intent-not-code]] (the same rot one
  level down) and [[reproduce-outside-the-tool-first]] (the general habit).
