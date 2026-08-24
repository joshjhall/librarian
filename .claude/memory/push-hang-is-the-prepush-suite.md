---
name: push-hang-is-the-prepush-suite
description: "A git push that hangs while fetches are instant is the lefthook pre-push suite, not the network — give it ~10 min, never --no-verify"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8fd5bc08-523d-47c6-96be-ee5a00c30ae5
  modified: 2026-08-23T04:50:14.648Z
---

A `git push` in this repo runs lefthook's **pre-push** hook, whose `quality-gates`
step is the full `tests/run-all.sh` suite. Measured on PR #770: **461 s (7.7 min)**
before a single byte reaches the network. The default 2-minute Bash timeout kills
it every time, and a killed push leaves **no remote branch** — so it reads as a
network failure and invites a pointless retry loop, each retry re-running the whole
suite.

**Why:** the hook runs to completion *before* the transfer, so the push looks hung
while the machine is busy locally.

**The tell that it is NOT the network:** `git ls-remote` / `git fetch` return
instantly against the same remote. Reads do not fire pre-push; only writes do. An
asymmetry that sharp is a local hook, not congestion — cf.
[[reproduce-outside-the-tool-first]].

**Confirm in one bounded call:** `timeout 60 git push --dry-run origin <branch>`
exits 124 while printing the lefthook banner and per-gate progress, naming the
culprit directly.

**Fix:** re-run the push with `timeout: 600000` on the Bash call. Do **not** reach
for `--no-verify` ([[no-noverify-fix-the-lint]]) — and note the hook is not even
failing here, just slow, so there is nothing to "fix" but the budget. Start any push
from this repo with a generous timeout rather than discovering the hang.
