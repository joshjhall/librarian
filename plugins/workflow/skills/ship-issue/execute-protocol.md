# Step 4 — Execute (protocol detail)

Companion to `ship-issue/SKILL.md`. Load this during Step 4. SKILL.md keeps
**Option 1's create → commit → push → open-PR** happy path inline; this file
carries the rest: Option 1's post-PR loop (CI → review → merge gate → labeling →
completion summary) and the two alternate shipping modes (Option 2 — commit to
main + push; Option 3 — commit only). The merge invariant and the level-aware
merge dispatch are authoritative in `orchestrate/autonomy-levels.md` and
summarized in SKILL.md `## Autonomy Level`.

## Option 1 — Branch + PR: after the PR is open

Continue here once `gh pr create` / `glab mr create` has opened the PR.

1. **Monitor CI, run the multi-cycle review loop, and file deferred findings**
   — **Companion file**: `ci-review-protocol.md` in this skill directory carries
   the full protocol for these three post-PR-creation steps. This loop always
   runs before any merge — there is no path that skips it. In brief:

   - **Monitor CI and remediate failures** (advisory; `ci-fixer` caps fixes at 3
     attempts per check). An L3–L4 run always waits. Poll `gh pr checks` every
     30 s against the `LIBRARIAN_CI_WAIT_TIMEOUT` checkpoint (L3–L4 auto-extends
     up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS`, then STOPs). On failure, **triage
     infra-flake vs real first** (classify by failing-step name vs the diff;
     auto-retry an infra flake once via `gh run rerun --failed`; collapse cascade
     failures to their root cause), then hand real failures to the `ci-fixer`
     `workflow.js` harness — applying its commits (hard-filtered against the
     CI-config denylist), pushing, and re-polling.
   - **Multi-cycle PR review loop** (after green CI) — re-run the `workflow.js`
     harness (`phase: "pr-cycle"`) folding in open PR comments, resolve `blocking`
     / file `deferrable`, commit + push + re-check CI each cycle, terminate when
     clean + green + every comment resolved-or-deferred (cap `REVIEW_MAX_CYCLES`).
   - **File deferred review findings** — file each via `/workflow:file-issue` (autonomous
     fallback: `gh issue create --body-file`, never interpolating LLM text into a
     shell arg), link them on the PR, and append a "Review findings" section to
     the PR body. Nothing is silently dropped.

   Every sub-step degrades gracefully (a missing harness/`gh` is skipped with a
   note, never a hard-fail) and never prompts at L3–L4. See
   `ci-review-protocol.md` for the commands, the failure-triage classifier, the
   loop-termination rule, and the deferred-filing safety contract.

1. **Merge gate — level-aware, merge on green CI + clean review.** Reached only
   once the loop above **terminated green + clean** (CI green, `clean` true, every
   PR comment resolved-or-deferred). This is the **routine-gate merge** — merge
   *because* CI is green AND the review loop ran AND came back clean.

   **The merge invariant is checked first, at every level (incl. L4):** if the
   loop did **not** reach green + clean — CI still red after `ci-fixer`'s cap, an
   unresolved blocking finding, or an unaddressed comment — this is a **dead-end**
   (`orchestrate/autonomy-levels.md`; #181). Do **NOT** merge at any level. Park
   the PR, emit the dead-end summary (what is un-green/unclean, what was
   attempted, what remains), leave `status/pr-pending` on the issue, and STOP for
   a human. Then skip the rest of this step.

   With the invariant satisfied, dispatch by level:

   - **L3–L4 — auto-merge, then prune (worktree-aware).** Merge the PR yourself
     (squash), then do the cleanup inline. First detect whether this run is in a
     **linked worktree** — an `EnterWorktree` session or an `orchestrate`
     per-golem worktree — because `main` is checked out in the **primary**
     worktree and git refuses a second checkout of it. Use the same `git
     rev-parse` idiom as `hooks/golem-notify.sh` and
     `scripts/seed-worktree-trust.sh`: `git rev-parse --git-dir` != `git rev-parse
     --git-common-dir` means a linked worktree (`IN_WORKTREE=1`); equal means the
     primary checkout (`IN_WORKTREE=0`). Merge on that flag —

     **Primary checkout** — merge with `--delete-branch`; `gh` fast-forwards the
     local `main`:

     ```bash
     gh pr merge "$PR_NUM" --squash --delete-branch
     ```

     **Linked worktree** — do NOT pass `--delete-branch` (it forces a local `git
     checkout main` to prune, which fails with `'main' is already used by worktree
     at …`). Merge without it, then delete the remote branch explicitly, which
     needs no local checkout:

     ```bash
     gh pr merge "$PR_NUM" --squash
     git push origin --delete "$BRANCH"   # remote prune; ignore "remote ref does not exist"
     ```

     **If `gh pr merge` exits non-zero, classify before calling it a dead-end.** A
     post-merge **cleanup** failure (the local `checkout main` in a worktree) is
     NOT a merge refusal — the server-side merge already landed. Check the PR's
     real state with `gh pr view "$PR_NUM" --json state -q .state`: a state of
     **`MERGED`** means the merge succeeded and the non-zero was cleanup — this is
     **not** a dead-end, so finish the remote-branch delete if it did not run
     (`git push origin --delete "$BRANCH"`, ignore "remote ref does not exist")
     and continue to the cleanup steps below. **Any other state** (`OPEN`, blank)
     is a genuine refusal (branch protection needs a human approval the golem
     can't supply, or merge is disabled): treat it as a **dead-end** — log the
     error, leave the PR open + labeled, emit the dead-end summary, and STOP for a
     human. Never loop-retry a merge the platform refused.

     The cleanup steps below run on **both** the clean-merge and the
     MERGED-after-cleanup-failure paths. Steps a and b hit the API, not the local
     tree, so a failed local checkout can never strand the label swap (the exact
     half-finish issue #225 reports):

     a. Label the issue `status/pr-pending` → the `Closes #{N}` in the PR body
     closes it on merge; remove `status/in-progress`:

        ```bash
        gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"
        ```

     b. Comment on the issue:

        ```bash
        gh issue comment {N} --body "Fix merged in PR #{pr_number} (squash + delete-branch) after green CI + clean review."
        ```

     c. **Primary checkout only:** `git checkout main` (then `git pull` to
     fast-forward the merge). **Skip in a linked worktree** (`IN_WORKTREE=1`) —
     its HEAD need not move and the golem worktree is torn down by
     `worktree-rm.sh`.
     d. Delete the state file (`.claude/memory/tmp/next-issue-{N}.json`)
     e. Show the PR URL, then **exit** — skip the L1–L2 labeling/comment steps
     below and Step 5.

   - **L1–L2 — stop for a human merge.** Do NOT merge. Emit the completion
     summary (CI green, review clean, PR URL) and hand off to a human to merge —
     today's default behavior. Continue to the labeling + comment steps below,
     then Step 5.

   **Squash-by-default rationale**: `/workflow:next-issue` PRs are single-issue,
   single-deliverable units; squash keeps history linear and the merged commit
   still references the issue.

1. **Label the issue** `status/pr-pending` and remove `status/in-progress`
   (L1–L2 path; the L3–L4 path already did this inline above):

   - GitHub: `gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/pr-pending" --unlabel "status/in-progress"`

1. **Comment on the issue**:

   If CI remediation was performed, include a summary in the comment:

   - GitHub: `gh issue comment {N} --body "Fix submitted in PR #{pr_number}. CI remediation: {N} fix(es) applied automatically."`
   - GitLab: `glab issue note {N} --message "Fix submitted in MR !{mr_number}. CI remediation: {N} fix(es) applied automatically."`

   If no CI remediation was needed or CI was skipped:

   - GitHub: `gh issue comment {N} --body "Fix submitted in PR #{pr_number}"`
   - GitLab: `glab issue note {N} --message "Fix submitted in MR !{mr_number}"`

1. **Checkout main**: `git checkout main` — **skip in a linked worktree**
   (`git rev-parse --git-dir` != `--git-common-dir`; see the L3–L4 detection
   above), where `main` is checked out in the primary worktree and the checkout
   would fail with `'main' is already used by worktree at …`.

1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`)

1. **Show the PR/MR URL** to the user

1. **Completion summary** (L2 only; L1 falls through to the interactive Step 5) —
   after green CI + clean review, labeling, and the issue comment, emit a
   STRUCTURED COMPLETION SUMMARY and STOP for a human to merge. (An L3–L4 run
   already merged and exited above; an L1 interactive run uses Step 5's prompt.)
   Format as a markdown block:

   ```markdown
   ## Ship summary (L{1-2} — ready for human merge)

   - **Issue**: #{N} — {title}
   - **PR/MR**: {pr_or_mr_url}
   - **Branch**: {branch}
   - **CI**: {green | stopped-with-failure: {detail}}
   - **CI fixes applied**: {count} — {one-line summaries}
   - **Review cycles**: {cycles} run (cap {REVIEW_MAX_CYCLES})
   - **Review status**: {clean | stopped-with-blocking: {detail}}
   - **Findings fixed**: {count} blocking, on this PR
   - **Findings deferred**: {#A, #B (filed), or "none"}
   - **Comments resolved-or-deferred**: {n}/{total}
   - **Deferred notes**: {drift / branch-freshness / pre-review findings, or "none"}
   - **Plan comment**: {plan_comment_url, if present}

   CI green + review clean. At L1–L2 the merge gate is a human's — ready for
   human merge. (An L3–L4 run would have auto-merged.)
   ```

   Then STOP — do not proceed to Step 5.

## Option 2 — Commit to main + push

1. Ensure on `main` (or warn if on a different branch and confirm)

1. **Stage and commit** with `Closes #{N}` in the body (same format as Option 1)

1. **Verify** the commit message includes `Closes #{N}`

1. **Push**:

   ```bash
   git push origin main
   ```

1. **Remove `status/in-progress` label**:

   - GitHub: `gh issue edit {N} --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --unlabel "status/in-progress"`

1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`;
   the `Closes` keyword auto-closes the issue on push)

1. Tell the user the issue will auto-close when the push is processed

## Option 3 — Commit only (no push)

1. **Stage and commit** with `Closes #{N}` in the body (same format as Option 1)
1. **Verify** the commit message includes `Closes #{N}`
1. **Do NOT push**
1. **Label the issue** `status/commit-pending` and remove `status/in-progress`:
   - GitHub: `gh issue edit {N} --add-label "status/commit-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/commit-pending" --unlabel "status/in-progress"`
1. **Comment on the issue** with the commit SHA:
   - **Agent mode** (branch matches `^agent`):
     - GitHub: `gh issue comment {N} --body "Agent {branch} committed fix. Ready for orchestrator review. Commit: {sha}"`
     - GitLab: `glab issue note {N} --message "Agent {branch} committed fix. Ready for orchestrator review. Commit: {sha}"`
   - **Normal mode**:
     - GitHub: `gh issue comment {N} --body "Fix committed locally (not yet pushed). Commit: {sha}"`
     - GitLab: `glab issue note {N} --message "Fix committed locally (not yet pushed). Commit: {sha}"`
1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`)
1. Tell the user the commit is local and needs to be pushed later
