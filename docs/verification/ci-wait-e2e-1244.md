# ci-wait.sh — live verification in a worktree-isolated session (#1244)

AC3 of #1244: *the documented recipe is accepted in a worktree-isolated session
and stops at the ceiling.* This session ran `/workflow:golem 1244`, so Phase B's
`EnterWorktree` had isolated it — the same state every golem runs in.

## 1. The documented recipe is accepted — VERIFIED (live)

The recipe from `ship-issue/ci-monitor-protocol.md` § a, with
`<skill-base-dir>` substituted literally, run as a `run_in_background` Bash
task (the documented shape) against an already-green PR:

```text
/workspace/librarian/.worktrees/issue-1244/plugins/workflow/skills/ship-issue/../../scripts/ci-wait.sh 1242 --level 3
```

Output, read from the task's own output file (not the wrapper's status):

```text
result=pass
verdict=-
elapsed_min=0
extensions_used=0
ceiling_min=-

[exited with code 0]
```

No isolation refusal. For contrast, the same session refused the shapes the
issue reported — a compound command with a heredoc, and `bash <script> > log
2>&1` — with the "too complex to verify" message, so the harness was enforcing
isolation while it accepted the recipe.

## 2. It stops at the ceiling — see below

Recorded against this PR's own pending CI, after the push.
