---
description: Run a single issue end-to-end as a solo "golem" in the current session — create an isolated git worktree, work the issue there through the next-issue → ship-issue pipeline at a chosen autonomy level (L1–L4), then tear the worktree down. Use when you want one issue worked with full golem rigor (including the adversarial pre-PR review) and worktree isolation, without an orchestrator, tmux, or containers. For 2+ parallel issues, use /workflow:orchestrate instead.
---

# Golem (solo, in-session)

`/workflow:golem` runs **one** issue the way an orchestrated golem does — its own
worktree, its own branch, the full `next-issue → ship-issue` pipeline, the same
adversarial pre-PR review — but **in the primary session**, with no orchestrator,
no `tmux`, and no container. You are the golem; you monitor it by watching your
own session. Every gate (plan approval, escalation, dead-end, permission) surfaces
in-session as a normal prompt, so none of the detached-golem apparatus (feed,
`golem-status.sh`, gate-watch, inbox, `golem-launch.sh`) is involved.

It is a **thin wrapper**: `/workflow:golem` owns only the worktree lifecycle and teardown
timing. **All issue work is delegated** — selection, planning, implementation,
testing, review, PR, and merge all run through `/workflow:next-issue` (which chains
`/workflow:ship-issue` in-turn at L3–L4). The worktree keeps the **main checkout free for
the human** and lets multiple terminals work different issues in parallel without
collision.

For 2+ issues in parallel, or detached/headless work, use **`/workflow:orchestrate`**
(dispatches golems as processes) — not this skill.

## Command

```text
/workflow:golem [N] [--level M] [--teardown N]
```

- **`N`** (optional) — the issue number to work. Omitted → priority-select (below).
- **`--level M`** (optional, 1–4) — the run's autonomy level, passed straight to
  `/workflow:next-issue`. Omitted → `/workflow:next-issue` prompts L1–L4 (the "ask each run"
  default). `severity/critical` still caps at L3 (enforced by `/workflow:next-issue`).
- **`--teardown N`** — post-merge cleanup re-entry for an L1–L2 run whose PR was
  merged out-of-band (see Phase D). Mutually exclusive with a normal run.

## Workflow

### Phase A — Preflight & guards

1. **Nesting guard.** Refuse if this session is **already in a linked worktree** —
   don't nest golem worktrees:

   ```bash
   [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ] \
     && echo "Already in a linked worktree — run /workflow:golem from the main checkout." && exit
   ```

   (`git rev-parse --git-dir` != `--git-common-dir` means a linked worktree; equal
   means the primary checkout — the same idiom `ship-issue/execute-protocol.md`
   uses.)

1. **Detect platform** from `git remote -v` (same table `/workflow:next-issue` uses):
   `github.com`/`ghe.` → GitHub (`gh`); `gitlab.com`/`gitlab.` → GitLab (`glab`).

1. **Resolve the issue number `N` up front** — the worktree needs a concrete
   target before it is created:

   - **`N` given** → use it.
   - **Bare `/workflow:golem` (no `N`)** → **priority-select**. Run `/workflow:next-issue`'s priority
     query read-only (see `next-issue/state-format.md` § Priority Ordering for the
     exact `gh`/`glab` commands — the nested severity × effort walk, excluding
     `status/in-progress` etc. and applying the blocked-by exclusion). Take the
     first open, unassigned, unblocked issue, **show it** (number, title, labels),
     and **confirm with the operator** before creating the worktree. Do not
     re-implement the full selection loop — reuse those commands only to resolve
     `N`.

1. **Worktree collision guard.** If `.worktrees/issue-N` already exists, offer to
   **resume into it** (`EnterWorktree`, skip Phase B's create) rather than
   recreate — a prior `/workflow:golem` run for this issue may have paused.

### Phase B — Create + enter the worktree

1. Create the golem-standard worktree (branch `feature/issue-N` from
   `origin/main`, with machine-local files copied in, workspace trust seeded, and
   submodules initialized — all handled by the script):

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/worktree-new.sh N
   ```

1. Move **this session** into it:

   ```text
   EnterWorktree({ path: ".worktrees/issue-N" })
   ```

   The branch prefix is `feature/` on purpose — it does **not** match
   `ship-issue`'s `^agent` commit-only detection, so a solo run pushes and opens a
   PR normally (unlike a container golem's `agent{N}` branch).

1. **Stay inside the worktree — never edit the main checkout (#475).** From here
   on this session's cwd is the worktree. Address every `Edit`/`Write`/`Bash`
   file target by a **worktree-relative** path (`plugins/...`) or a
   **`$PWD`-anchored** absolute path — **never** a bare main-checkout root path
   (`/workspace/<repo>/plugins/...`, or a path copied from a doc/grep result that
   is rooted at the main checkout). Git worktrees share no filesystem-level
   protection, so an absolute path aimed at the main tree writes there
   **silently**: the worktree's `git status` stays clean and the leak only
   surfaces as a stray dirty file on `main` (which is often on a *stale* base, so
   a blind recovery can revert an already-merged PR). The bundled
   `hooks/worktree-guard.sh` PreToolUse guard **blocks** an `Edit`/`Write` whose
   absolute target lands in the main checkout outside this worktree — if you hit
   that denial, re-issue the edit against the worktree path it names.

   **If a file was already leaked into the main checkout** (e.g. from a `Bash`
   `>` redirect, which the guard does not cover): restore **only** that file in
   main — `git -C <main-root> checkout -- <leaked-file>` — then re-apply the
   change **fresh in the worktree** on the correct base. **Never** blind-copy the
   leaked file from main into the worktree: the main checkout may be behind
   `origin/main`, so copying stale bytes can revert a since-merged PR
   (the stale-base-squash-reverts-merged-pr class).

### Phase C — Run the pipeline

Invoke `/workflow:next-issue` via the **Skill tool**, passing `N` and any `--level`:

```text
Skill(next-issue)  with args:  N [--level M]
```

`/workflow:next-issue` then owns everything: it prompts L1–L4 if no level was given, builds
the plan (human gate at L1–L3, auto at L4), implements, tests, and:

- **L3–L4** — chains `/workflow:ship-issue` **in the same turn** → Branch + PR → wait for
  CI + adversarial review → **auto-merge** on green + clean. Control returns here
  for Phase D.
- **L1–L2** — stops at the routine ship gates. The human runs `/workflow:ship-issue` (now
  or later); it stops again for the human to merge. `/workflow:golem` does not force it.

The adversarial pre-PR review runs identically to an orchestrated golem's — that
parity now holds across **all** shipping modes (see `ship-issue/pre-ship-validation.md`
check #6), so a solo run cannot skip it by choosing commit-only.

### Phase D — Teardown (auto after merge, prompt otherwise)

- **L3–L4 (the PR auto-merged this turn):** leave the worktree, then prune it —
  in that order, automatically —

  ```text
  ExitWorktree({ action: "keep" })
  ```

  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/worktree-rm.sh N
  ```

  Report the merged PR URL.

  **`keep` + `worktree-rm.sh` IS the complete teardown — not a workaround, and
  not a step to "correct" back to `remove`.** Two independent reasons, both
  load-bearing:

  - **`remove` is unavailable.** `ExitWorktree` only removes a worktree *it*
    created via `EnterWorktree({ name })`. Phase B enters an **existing** one by
    **path** (`worktree-new.sh N` created it first), and the `ExitWorktree`
    contract says of that entry method: *"ExitWorktree will not remove a worktree
    entered this way; use `action: "keep"` to return to the original
    directory."* So `remove` refuses by contract, every run.
  - **The order is not cosmetic.** `worktree-rm.sh` performs the entire teardown
    itself — `git worktree remove` **plus** `branch -D` plus the `golem-N` tmux
    kill — so running it first deletes this session's own cwd out from under it.
    `keep` returns the session to the main checkout; the prune then runs from
    there.

  **Cross-ref #626** (move the golem worktree root to `.claude/worktrees/`). If
  that lands, golem worktrees sit where `EnterWorktree` natively places its own,
  which may make `EnterWorktree({ name })` viable and would make `remove`
  correct. Whichever lands second must **re-check** this sequence rather than
  assume it.

- **L1–L2 (human merges later):** the PR is **not** merged, so do **not** remove
  the worktree. Return the session to the main checkout so it's free for other
  work, and tell the human how to finish:

  ```text
  ExitWorktree({ action: "keep" })
  ```

  > PR open, awaiting your merge. When it lands, run `/workflow:golem --teardown N` to
  > prune the worktree and branch **and remove the now-stale `status/pr-pending`
  > label** — the squash commit closes the issue, but nothing takes the label off
  > on its own (#654). If you finish by hand instead, that label removal is part
  > of the job.

- **`--teardown N` re-entry:** verify the PR/branch actually **merged** before
  removing anything — key off the **merged PR / branch**, never the state file
  (`/workflow:ship-issue` deletes `next-issue-N.json` on completion, so it is already gone):

  ```bash
  gh pr view --json state,url --head feature/issue-N   # state == MERGED  (GitHub)
  glab mr view --source-branch feature/issue-N          # merged           (GitLab)
  ```

  If merged, **first sweep the stale `status/pr-pending` label off the issue**,
  then `ExitWorktree({ action: "keep" })`, then `worktree-rm.sh N`.

  `/workflow:golem --teardown N` **owns** this sweep (#654). The label is added
  when the PR opens and is correct for as long as the PR sits unmerged, but on
  the parked and L1–L2 paths the merge happens *after* `/workflow:ship-issue` has
  already exited — no step of ship is left to clean up, and the squash commit's
  `Closes #{N}` trailer closes the issue with the label still on it. This
  re-entry is the natural owner because it is already the documented post-merge
  step and has **already verified `state == MERGED`** immediately above:

  ```bash
  gh issue edit {N} --remove-label "status/pr-pending"        # GitHub
  ```

  ```bash
  glab issue update {N} --unlabel "status/pr-pending"         # GitLab
  ```

  Two properties this relies on:

  - **Merged-only.** The sweep runs **only** on the verified-MERGED branch. The
    not-yet-merged branch below stops without removing anything, and must
    **keep** the label — an unmerged PR is genuinely awaiting merge, which is
    exactly what the label is for.
  - **Idempotent.** Removing an already-absent label is a clean no-op:
    `gh issue edit --remove-label` exits 0 when the label exists in the repo but
    is not on the issue, and errors only when the label does not exist in the
    **repo** at all. So a re-run of `--teardown N`, or a PR that reached merge
    without ever being parked, costs nothing. Do **not** wrap it in `|| true` —
    that would swallow the repo-missing case, which is a real misconfiguration
    worth surfacing.

  Then prune — same order and same action as the L3–L4 block above, for the same
  two reasons (`remove` refuses on a path-entered worktree; prune-first deletes
  the cwd). A
  `--teardown` re-entry usually runs from the **main checkout** already, where
  `ExitWorktree` is a documented no-op — call it anyway, so the one case that
  matters (re-entry from inside the worktree) is covered. If not yet merged, say
  so and stop (do not remove an unmerged worktree —
  `worktree-rm.sh` also refuses on uncommitted changes as a backstop).

## When to Use

- One issue you want worked with **full golem rigor** — the adversarial pre-PR
  review, the plan gate, the drift/pre-review checks — and **worktree isolation**,
  but without standing up an orchestrator or containers.
- You want to **watch the work directly** in your own session instead of attaching
  to a detached `tmux`/container golem.
- Keeping the **main checkout free** for your own edits (or another terminal's
  `/workflow:golem`) while this issue runs in its own worktree.
- **Smoothest at L3–L4** (chains straight through to merge + auto-teardown) or on
  `effort/trivial`/`small` issues. At **L1–L2 on a medium/large** issue,
  `/workflow:next-issue` reaches its "After plan approval" context reset that suggests
  `/clear` (`next-issue/state-format.md`); inside an `EnterWorktree` session a
  `/clear` may drop the worktree cwd. `/workflow:next-issue` now emits a **worktree-aware**
  resume hint for that case — its `/clear` suggestion tells you to re-enter this
  worktree (`EnterWorktree({ path: ".worktrees/issue-N" })`) before `/workflow:next-issue`,
  so the run resumes from implementation without your having to reconstruct the
  cwd by hand. L3–L4 remains the smoothest hands-off run (it bypasses the reset
  entirely); `/workflow:golem --teardown N` still prunes the worktree once the PR merges.

## When NOT to Use

- **2+ issues in parallel**, a fixed worker pool, or an integration train — use
  **`/workflow:orchestrate`** (dispatches golems as processes and monitors them centrally).
- **Detached / headless** work you won't watch live — again `/workflow:orchestrate`
  (tmux/container golems).
- **From inside an existing worktree** — the nesting guard refuses; run from the
  main checkout.
- A quick, isolation-free fix on the current branch — plain `/workflow:next-issue` (Mode 1)
  is lighter.
