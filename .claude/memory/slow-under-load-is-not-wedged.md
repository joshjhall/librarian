---
name: slow-under-load-is-not-wedged
description: Elapsed time alone cannot distinguish a wedged process from a slow one; check for an advancing child and real memory pressure before concluding "stranded"
metadata:
  type: feedback
---

A long-running process is not evidence of a stuck one. Under contention (several
golems on one host) a job that takes ~19 minutes unloaded takes far longer, and
looks identical to a hang if the only signal read is `etime`.

**Why:** I twice diagnosed a pre-push suite as "stranded" from elapsed time plus
a killed parent, and proposed killing it — once even proposing `--no-verify` on
the strength of that diagnosis. Measurement contradicted both premises: the tree
was actively running `lint-shell-portability.sh` and progressing, and memory was
not exhausted (13.5GB of 24GB available, no OOM kills). The real cause was load
average 12.6 from concurrent golems.

**How to apply:** Before calling anything stranded, measure two things.
(1) *Is it advancing?* `pgrep -P <pid>` down the tree and look for a live,
changing child — a wedged tree has no working descendant.
(2) *Is the resource actually gone?* `free -m` and `uptime`; a high load average
with free memory is contention, not exhaustion, and the fix is to wait.
A "killed" notification for a wrapper does not mean the work under it died.
Never let a resource diagnosis become the justification for skipping a gate
([[no-noverify-fix-the-lint]]) — see also
[[push-hang-is-the-prepush-suite]] and [[prepush-hook-already-runs-the-suite]].
