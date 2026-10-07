# Harness staging from an installed plugin — #1174

**Verdict:** the refusal came from a **stale install**, not from the current
recipe. The current recipe (`harness-stage.sh`, #1029) stages the harness
outside `.claude/memory/`. This issue adds the one missing guarantee from AC3:
the staged copy is verified byte-identical **at runtime** before its path is
printed.

## AC1 — the refusal, as recorded

Both golems on 2026-10-07 passed the installed path directly to the `Workflow`
tool. Each got this refusal, verbatim from both transcripts
(`~/.claude/projects/-workspace-librarian--worktrees-issue-1082/6d81727d-….jsonl`,
`…-issue-1105/dbd0b217-….jsonl`):

```text
scriptPath must be a script path this tool returned, or a file you can already
read (the working directory or a directory you have added):
/opt/librarian/plugins/workflow/skills/ship-issue/workflow.js
```

After the refusal, each golem copied the harness by hand: #1082 to
`.claude/memory/tmp/ship-issue-workflow.js` (9 uses), and #1105 to
`.claude/memory/tmp/ship-review-workflow.js` (18 uses). Neither transcript ever
calls `harness-stage.sh`.

## Why — the image carries a release that predates the stager

| Fact | Value |
| --- | --- |
| `/opt/librarian/VERSION` in the running devcontainer | `0.14.0` (files dated 2026-09-12) |
| `harness-stage.sh` introduced | #1029 (`a606c1a`, 2026-09-13), first tag `v0.15.0` |
| `/opt/librarian/plugins/workflow/scripts/harness-stage.sh` | absent |
| Installed `pre-ship-validation.md` L321 | `~/.claude/skills/ship-issue/workflow.js` (the pre-#973 path that resolves nowhere) |
| `containers` submodule `Dockerfile` | `ARG LIBRARIAN_REF=v0.15.0` |
| Latest release | `v0.16.0` |

The #1082 golem first probed `~/.claude/skills/ship-issue/workflow.js`, exactly
as the installed v0.14.0 prose says. That missed, so it fell back to
`/opt/librarian/...`, and the tool refused it. The current tree already routes
every invocation through `harness-stage.sh`: `tests/lint-harness-paths.sh`
reports 142 passed, 0 failed.

## AC2/AC3 — the current recipe, exercised in this session

The source is forced to the installed path, and the stage root is a scratch
directory outside the worktree:

```text
$ LIBRARIAN_HARNESS_SHIP_ISSUE=/opt/librarian/plugins/workflow/skills/ship-issue/workflow.js \
    bash plugins/workflow/scripts/harness-stage.sh stage ship-issue --dir /tmp/hs-probe-1174
path=/tmp/hs-probe-1174/.claude/tmp/harness/ship-issue.workflow.js
source=/opt/librarian/plugins/workflow/skills/ship-issue/workflow.js
staged=true
rc=0
```

- The copy lands in `.claude/tmp/harness/`, **not** `.claude/memory/`, and
  `git check-ignore` reports it ignored (`.gitignore:65: tmp/`).
- From a dev checkout the harness is already under cwd, so the script prints
  `staged=false` and makes no copy.
- A copy cannot be avoided entirely for an out-of-cwd install: the tool accepts
  only a `scriptPath` under cwd.

**Gap closed here:** before this change, `cmd_stage` trusted the exit statuses
of `cp`/`mv`. A copy that exits 0 over a short write would still print `path=`.
The script now runs `cmp` on the installed file against its source and refuses
with exit 3 (and removes the file) on a mismatch. This is pinned by
`test_staged_copy_mismatch_refuses`, which uses a PATH-stub `cp` that truncates
and exits 0. Mutation check: with the `cmp` guard replaced by `if false`, that
test fails.

## Remaining action

**Not fixable in this repo's plugin code:** the devcontainer must be rebuilt
against a release ≥ v0.15.0 (and the `containers` pin bumped to v0.16.0).
Until then, a golem in this image reads v0.14.0 prose and hits the same refusal.
