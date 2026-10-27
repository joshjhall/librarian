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

## 2. It stops at the ceiling — VERIFIED (live)

Run against this PR, #1245, immediately after `gh pr create`, while its CI
checks were still running. The same isolated session and the same
`run_in_background` shape were used. The carried `--elapsed-min` places the
wait at the ceiling, so the first pending poll must return `stop`:

```text
/workspace/librarian/.worktrees/issue-1244/plugins/workflow/skills/ship-issue/../../scripts/ci-wait.sh 1245 --level 4 --elapsed-min 45 --extensions-used 2
```

Output, read from the task's own output file:

```text
result=pending
verdict=stop
elapsed_min=45
extensions_used=2
ceiling_min=45

[exited with code 9]
```

The run was accepted with no isolation refusal. It read the checks as pending,
and `ci-wait-timeout.sh`'s verdict stopped it at the default 45-minute ceiling,
with exit 9 as documented. Note that the harness labels a non-zero background
exit as "failed". Here exit 9 is the designed `stop` signal, so the output above
is the authoritative record, not that label.

The bound accrues over real wall time in the same loop. That part is pinned
offline by `tests/validate-ci-wait.sh`, in "stuck CI stops at the 45-min
ceiling (exit 9)", which uses a stubbed clock: it walks 0 → 45 minutes through
both L4 extensions. That loop is not re-run live here, because it would hold
CI for 45 minutes.
