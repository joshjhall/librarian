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

## 2. It stops at the ceiling — DEFERRED (needs a PR with pending CI)

Not observed yet: the only green-and-pending PR this session can reach is its
own, which does not exist until the push. The offline half is pinned by
`tests/validate-ci-wait.sh` ("stuck CI stops at the 45-min ceiling (exit 9)",
"LIBRARIAN_CI_WAIT_* reach the bound"), with `gh` and the clock stubbed.

Recipe, from the isolated worktree, while `{pr}`'s checks are still running.
The carried `--elapsed-min` places the wait at the ceiling, so the first
pending poll must return `stop`:

```text
<repo>/plugins/workflow/skills/ship-issue/../../scripts/ci-wait.sh {pr} --level 4 --elapsed-min 45 --extensions-used 2
```

Expected: `result=pending`, `verdict=stop`, `ceiling_min=45`, exit `9`, and no
isolation refusal. If the checks have already finished, the run exits 0 or 1
instead, and this section stays DEFERRED. That outcome says nothing about the
ceiling.
