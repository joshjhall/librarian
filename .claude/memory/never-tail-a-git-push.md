---
name: never-tail-a-git-push
description: "piping git push through tail/head hides the hook rejection line — verify by comparing the remote SHA to HEAD, never by the pipeline's exit code"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 33c5bf10-08a5-4c5a-8d5b-ce6c36897448
  modified: 2026-07-29T23:05:36.123Z
---

Never pipe `git push` through `tail`/`head`, and never treat the pipeline's exit
code as the push's. `tail -2` on a push in this repo shows the lefthook footer
and the final `error:` line — or crops the rejection entirely — while
`$?` reports the *last* command in the pipe. A rejected push then reads as a
clean success.

**Why:** lefthook's pre-push runs the full `tests/run-all.sh` plus `typos`, and
prints its verdict BETWEEN the ref lines and the trailing error. The signal is in
the middle of the output, which is exactly what `tail` discards. This bit twice
in one session on PR #575: the branch sat two commits behind origin while I
reported it in sync, because `typos` had flagged an illustrative misspelling
inside a code comment.

**How to apply:** run `git push` unpiped, or verify the landing rather than the
command — `[ "$(git ls-remote --heads origin <branch> | cut -f1)" = "$(git rev-parse HEAD)" ]`.
When a push is slow (the pre-push suite takes minutes here), background it and
poll the remote SHA; do not shorten the output to make it fit.

Generalizes: any tool's exit status read through a pipe is the pipe's, not the
tool's — the same class as `grep -c` exiting 1 on a zero count, and as a failing
`$(...)` inside a larger command not aborting under `set -e`.

Related: [[verify-squash-merge-landed]], [[grep-c-zero-count-exit-1]],
[[typos-gate-blocks-push]].
