# Orchestrate — Phase T: Integration Train

Companion to `orchestrate/pool-train-protocol.md`, split out of it in #973 when
that file passed its prose budget. It carries **Phase T** in full: landing a
batch of green, approved PRs end-to-end (merge → rebase the next → merge) under
one up-front authorization, with CI re-run cost bounded.

The seam is the pool/train boundary the protocol already names: **the pool feeds
work in, the train lands it.** They run at different times, are invoked by
different commands (`pool`/`tracks` vs `train`), and share only the set of PRs
that have gone green.

Sequencing and CI-subset policy live in `merge-protocol.md` § *Integration Train
— Sequencing & CI-Subset Policy*; this file is the step-by-step.

## Phase T — Integration Train

Land a **batch** of already-green, already-approved PRs end-to-end —
merge → rebase the next → merge — with **one up-front authorization** instead of
one human gate per merge/rebase/push, and with CI re-run cost bounded. This is
the automation of the merge→rebase→merge chain the human used to drive by hand
(see `merge-protocol.md` § *Integration Train — Sequencing & CI-Subset Policy*).

The train is **not** a new merge mechanism — it is **sequencing + batch
authorization** layered over the existing pieces: the order is computed by
`workflow.js` (`mode: 'train'`), each rebase is the existing Phase R
(`poll+rebase`), and every outward action still flows through the live session's
`ask` gates. The orchestrator still never merges a golem branch into its own.

1. **Assemble the batch.** Run Phase M and take the PRs that are merge-ready
   (`ci: passing`, `review: approved`/`none`, `blocking: false`) — or the
   explicit `<N…>` list. A PR that is not green + review-clean is **excluded**
   from the train (the train lands approved work; it does not wait on red CI or
   open review). Report the excluded PRs so the human sees what is held back.

1. **One up-front batch approval.** Authorize "**land this batch**" **once** via
   `AskUserQuestion` (skipped when autonomous — see below). This single consent
   replaces the per-step merge/rebase/push prompts. It does **not** dissolve the
   safety boundary: the outward-action `ask` rules on `git push` /
   `gh pr merge` / `gh pr create` remain in force for every individual action —
   the operator simply grants the batch once rather than N times.

1. **Compute the merge order.** Gather each PR's changed-file list
   (`gh pr view <N> --json files`), stage the harness
   (`${CLAUDE_PLUGIN_ROOT}/scripts/harness-stage.sh stage orchestrate`, #973)
   and invoke the Workflow tool on its `path=` with:

   ```text
   args: {
     prs:  [{ number, branch, issue, golem, files: [<changed paths>] }, …],
     base: "<base branch, e.g. main>",
     mode: "train"
   }
   ```

   **Bound this invocation in wall-time (#224)** — `train` spends a read-only
   subagent per PR that arrived without a `files` list; invoke it as a background
   task with the caller-side timeout. A timed-out train run is **partial** —
   re-run it to recompute the order rather than landing a batch from an
   incomplete graph. See `mode-protocol.md` § *Bounding a Workflow invocation in
   wall-time*. (Passing each PR's `files` up front avoids the fetch agents.)

   The harness returns `train` = `{ independents, chains, waves, order, unresolved }`
   computed purely from pairwise file-overlap (no merge, no push, no rebase):

   - **`independents`** — PRs that share no changed file with any other; land in
     any order, **no rebase between them**.
   - **`chains`** — overlap components (≥2 PRs touching a common file), each
     ordered; land **in sequence**, rebasing each onto the prior merge.
   - **`waves`** — wave 0 = all independents + every chain head (mergeable
     immediately, in parallel); wave *k* = the *k*-th link of each chain (only
     mergeable after the (*k*−1)-th merges).
   - **`unresolved`** — `[{ pr, reason }]`: PRs whose changed-file set could
     **not** be fetched this run (`reason` ∈ `budget-skipped` / `tainted-ref` /
     `fetch-failed`). These are **fail-closed** (#272): excluded from the overlap
     graph entirely, so they never appear in `independents`/`chains`/`waves`/
     `order`. An unknown file set means unknown overlap — treating it as
     no-overlap (wave 0) would merge it out of order ahead of a chain it might
     collide with. **Do not merge these in wave 0.** Re-fetch each PR's files
     (`gh pr view <N> --json files`) and re-run train to place it, or land them
     **last and one at a time** after every wave, re-polling for CI/behind-base
     between each. When `budget_exhausted` is also true, the budget floor was
     hit mid-fetch — prefer re-running train (with a fresh budget or the files
     supplied) over trusting a partial order.

1. **Drive the loop** (loop-until-dry, resumable):

   1. **Merge wave 0** — every independent + each chain head. Prefer
      `gh pr merge <N> --auto --squash --delete-branch` so GitHub merges each the
      moment its already-green checks settle (no manual merge + wait); fall back
      to a direct `gh pr merge` where `--auto` is unavailable. Independents need
      no rebase, so they land without re-triggering CI.
   1. **For each chain, advance one link:** after the chain's current head
      merges, the next link is now behind base → run **Phase R**
      (`mode: "poll+rebase"`, scoped to that PR) to rebase it onto the new base.
      Post-#601 union handling resolves complementary same-region edits without
      escalation; only genuinely contradictory conflicts surface to the human.
   1. **Push** the rebased branch: `git push --force-with-lease origin <branch>`
      (the harness never pushes). Then merge it (`--auto` settle as above).
   1. **Repeat** until every wave is merged. Re-poll between waves to confirm CI
      stayed green and pick up any newly-behind PR.
   1. **Land `unresolved` PRs last.** After every wave has merged, handle
      `train.unresolved` (if non-empty) **one at a time**: re-fetch the PR's
      files (`gh pr view <N> --json files`) and re-run train to sequence it
      against `main` as it now stands, or merge it directly only once it is
      confirmed green + behind-base-clean against the post-train base. Never fold
      an `unresolved` PR into wave 0 — its overlap is unknown, so it must land
      after the sequenced batch, not in parallel with it.

1. **Bound CI cost.** A force-push after a rebase normally replays the full
   matrix. Reduce it per repo policy (see `merge-protocol.md`):

   - Use `gh pr merge --auto` so the PR merges on settle rather than after a
     manual wait — independents and no-conflict rebases add no full replay.
   - For a rebase whose only conflicts were docs/skills-only (union-resolved),
     require only the **changed-file** check subset to re-pass, not the whole
     build matrix, **where the repo's branch protection permits**.

   Merging is the level-aware routine gate (auto at L3–L4 after green CI + clean
   review; human-authorized at L1–L2 — see `orchestrate/autonomy-levels.md`).
   The train's single batch approval authorizes the *sequence*; it does **not**
   override the per-PR merge invariant.

1. **Honor stop/drain.** Between iterations, check the pool stop/drain signal —
   `pool.json` `queue` (Phase P). If it is `draining` (or `paused`), finish
   the in-flight merge/rebase, then halt the train cleanly (leaving remaining PRs
   open and labeled) rather than starting the next wave. When `pool.json` is
   absent (the pool was never engaged), there is no drain signal and the train
   runs every wave to completion — the check defaults to "keep going."

1. **Report** the train result: merged PRs (with order/wave), rebases
   auto-resolved (with strategy), and any escalations surfaced **verbatim** for
   the human. Never merge a golem branch into the orchestrator branch.

**Autonomous train.** When the orchestrator runs autonomously, skip the
`AskUserQuestion` batch approval (the batch is authorized by the autonomous
invocation) but keep every outward-action `ask` gate. A genuine conflict
escalation still stops the train for the human — the train automates the
*sequencing*, not the judgment.
