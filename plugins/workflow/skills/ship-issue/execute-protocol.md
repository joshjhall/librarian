# Step 4 — Execute (protocol detail)

Companion to `ship-issue/SKILL.md`. Load this during Step 4. SKILL.md keeps
**Option 1's create → commit → push → open-PR** happy path inline; this file
carries the rest: Option 1's post-PR loop (CI → review → merge gate → labeling →
completion summary) and the two alternate shipping modes (Option 2 — commit to
main + push; Option 3 — commit only). The merge invariant and the level-aware
merge dispatch are authoritative in `orchestrate/autonomy-levels.md` and
summarized in SKILL.md `## Autonomy Level`.

## Option 1 — Branch + PR: opening the PR

The mechanical half of Option 1 — branch, commit, verify, push, open the PR.
Moved here from `SKILL.md` in #503 so the whole of Option 1 reads as one
procedure in one file instead of breaking mid-sequence across two.

1. **Ensure on a feature branch**:

   - If currently on `main` (or the default branch), create and switch to a
     new branch using the naming convention from `next-issue/state-format.md`:

     ```bash
     git fetch origin main
     git checkout -b {prefix}/issue-{N}-{slug} origin/main
     ```

   - If already on a feature branch, stay on it

1. **Stage and commit**. The commit message MUST include `Closes #{N}` in
   the body:

   ```text
   {type}({scope}): {description}

   {optional body explaining the change}

   Closes #{N}
   ```

   Where `{type}` matches the branch prefix: `fix/` → `fix:`,
   `feature/` → `feat:`, `docs/` → `docs:`, `test/` → `test:`,
   `refactor/` → `refactor:`, `chore/` → `chore:`.

1. **Verify** the commit message: run `git log -1 --format=%B` and confirm
   `Closes #{N}` is present. If missing, amend to add it.

1. **Push** the branch:

   ```bash
   git push -u origin HEAD
   ```

1. **Create a PR**:

   - GitHub:

     ```bash
     gh pr create --title "{type}({scope}): {description}" --body "$(cat <<'EOF'
     ## Summary
     - {what changed and why}

     ## Test plan
     - {how this was tested}

     Closes #{N}
     EOF
     )"
     ```

   - GitLab:

     ```bash
     glab mr create --title "{type}({scope}): {description}" \
       --description "## Summary\n- {what changed and why}\n\n## Test plan\n- {how this was tested}\n\nCloses #{N}"
     ```

## Option 1 — Branch + PR: after the PR is open

Continue here once `gh pr create` / `glab mr create` has opened the PR.

1. **Monitor CI, run the multi-cycle review loop, and file deferred findings**
   — **Companion file**: `ci-review-protocol.md` in this skill directory carries
   the full protocol for these three post-PR-creation steps. This loop always
   runs before any merge — there is no path that skips it. In brief:

   - **Monitor CI and remediate failures** (advisory; `ci-fixer` caps fixes at 3
     attempts per check). An L3–L4 run always waits. Poll `gh pr checks` every
     30 s, calling `scripts/ci-wait-timeout.sh` each poll for the
     continue/extend/checkpoint/stop verdict it computes from
     `LIBRARIAN_CI_WAIT_TIMEOUT` + `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` (L3–L4
     auto-extends, then STOPs) — never re-derive that arithmetic by hand. On
     failure, **triage
     infra-flake vs real first** (classify by failing-step name vs the diff;
     auto-retry an infra flake once via `gh run rerun --failed`; collapse cascade
     failures to their root cause), then hand real failures to the `ci-fixer`
     `workflow.js` harness — applying its commits (hard-filtered against the
     CI-config denylist), pushing, and re-polling. Its `args` are the ci-fixer
     `checks` shape (`ci-review-protocol.md`), **not** the review keys below.
   - **Multi-cycle PR review loop** (after green CI) — re-run the `workflow.js`
     harness (`phase: "pr-cycle"`) folding in open PR comments, resolve `blocking`
     / file `deferrable`, commit + push + re-check CI each cycle, terminate when
     clean + green + every comment resolved-or-deferred **and** the convergence
     predicate says stop (ceiling `REVIEW_MAX_CYCLES`; #596). Its `args` keys:
     `phase`, `cycle`, `maxCycles`, `files`, `diff`, `prComments`, `issue`,
     `preScan`, `conventionsDigest`, plus the conditional delta trio
     (`deltaFiles`/`deltaDiff`/`priorBlockingDimensions`). Unknown keys are
     rejected and **none has a path/file variant** — pass `diff` inline at any
     size. Full block: `ci-review-protocol.md` step c.
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
   unresolved blocking finding, an unaddressed comment, **or a review that was
   skipped rather than run** — this is a **dead-end**
   (`orchestrate/autonomy-levels.md`; #181). Do **NOT** merge at any level. Park
   the PR, emit the dead-end summary (what is un-green/unclean, what was
   attempted, what remains), leave `status/pr-pending` on the issue, and STOP for
   a human. Then skip the rest of this step.

   **A skipped review is not a clean review (#637).** A `Review status` of
   `skipped: {reason}` fails this invariant exactly like `stopped-with-blocking`:
   at **L3–L4**, park with `status/pr-pending` and never auto-merge. `clean` was
   never established — no review ran to establish it. This is the `lint-python.sh`
   exit-77 rule applied to the review harness: a silent skip is indistinguishable
   from a pass, so it must render as a skip and gate like a failure, never fall
   through to `clean` because that is the only other value available. The
   mechanical-failure-only conditions under which a skip is even legitimate are in
   `pre-ship-validation.md` Step 3.5 item 6 and `ci-review-protocol.md`.

   With the invariant satisfied, dispatch by level:

   - **L3–L4 — auto-merge, then prune (worktree-aware).** Merge the PR yourself
     (squash), then do the cleanup inline.

     **Decide `--delete-branch` on whether a worktree HOLDS the branch — not on
     where this session is (#653).** `--delete-branch` makes `gh` prune the local
     branch, and git refuses to delete a branch that any worktree has checked
     out. That is a fact about **the branch**, not about the caller: merging from
     the **primary checkout** while the golem worktree still exists fails exactly
     the same way. Keying off session location misses that combination — and it
     is now the *routine* one, since #640 made golem Phase D park the session in
     the main checkout (`ExitWorktree keep`) **before** `worktree-rm.sh` prunes.

     ```bash
     BRANCH="$(gh pr view "$PR_NUM" --json headRefName -q .headRefName)"

     # Does ANY worktree hold this branch? (`--porcelain` prints one
     # `branch refs/heads/<name>` line per worktree.) Match with `-F -x`, never a
     # bare `-x`: `-x` anchors the whole line so `feature/issue-6` cannot match
     # `feature/issue-65`, and `-F` makes the branch name a LITERAL. Git allows
     # `.`, `[`, `*`, `^`, `$` in a branch name, all of which are regex
     # metacharacters — an unescaped `fix/v1.2` would match `fix/v1X2` and could
     # withhold `--delete-branch` on a branch no worktree actually holds.
     if git worktree list --porcelain | command grep -qFx "branch refs/heads/$BRANCH"; then
         gh pr merge "$PR_NUM" --squash              # a worktree holds it: local prune would fail
     else
         gh pr merge "$PR_NUM" --squash --delete-branch
     fi
     ```

     **Next, establish the PR's REAL state — before touching any branch.** Do
     this whatever `gh pr merge` returned, because its exit code answers a
     different question than "did the merge land":

     ```bash
     PR_STATE="$(gh pr view "$PR_NUM" --json state -q .state)"
     ```

     - **`MERGED`** — the merge landed. A non-zero exit here was a post-merge
       **cleanup** failure (e.g. the local `checkout main` in a worktree), NOT a
       merge refusal, so it is **not** a dead-end: proceed to the prune below and
       the cleanup steps.
     - **Any other state** (`OPEN`, blank) — a genuine refusal (branch protection
       needs a human approval the golem can't supply, or merge is disabled).
       Treat it as a **dead-end**: log the error, leave the PR open + labeled,
       emit the dead-end summary, and STOP for a human. **Do NOT run the prune
       below** — deleting the source branch of an unmerged PR is destructive and
       hard to recover once `worktree-rm.sh` has torn the worktree down. Never
       loop-retry a merge the platform refused.

     **Then, on the `MERGED` path only, prune the remote and VERIFY it is gone
     (#653 AC2 + AC3):**

     ```bash
     git push origin --delete "$BRANCH" 2>/dev/null || true   # tolerate "remote ref does not exist"

     # AC3 — RC is not proof of cleanup. VERIFY, don't infer.
     if [ -n "$(git ls-remote --heads origin "$BRANCH")" ]; then
         echo "WARNING: remote branch $BRANCH still present after prune" >&2
     fi
     if [ -n "$(git branch --list "$BRANCH")" ]; then
         # Do not ASSERT the reason — check it. A surviving local branch is
         # benign only if a worktree actually holds it; after the
         # `--delete-branch` arm it is the #652 bug itself.
         if git worktree list --porcelain | command grep -qFx "branch refs/heads/$BRANCH"; then
             echo "NOTE: local branch $BRANCH still present — a worktree holds it; worktree-rm.sh deletes it at teardown" >&2
         else
             echo "WARNING: local branch $BRANCH still present and NO worktree holds it — the local prune silently failed" >&2
         fi
     fi
     ```

     **"Unconditional" means "not gated on `gh`'s exit code" — not "regardless of
     whether the merge landed".** Those differ, and only the first is safe. Within
     the `MERGED` path the prune must **never** be gated on RC: when `gh` fails
     the local branch delete it **aborts the rest of its cleanup** — including the
     remote delete — while still **exiting 0**. Observed on PR #652:
     `state: MERGED`, `RC=0`, and `feature/issue-640` still on the remote
     afterward. A caller trusting `RC` alone concludes the branch was pruned when
     it was not — which is exactly why AC3 demands a **verify** rather than an
     inference, and why the check above reads the actual ref instead of an exit
     code. The prune is idempotent: on the `--delete-branch` arm the ref is
     already gone and the `|| true` absorbs the "remote ref does not exist".

     A **local** branch surviving is expected only when a worktree still holds it
     (the AC1 arm above) — `worktree-rm.sh` deletes it during teardown. So the
     check **re-tests that condition** rather than assuming it: after the
     `--delete-branch` arm no worktree holds the branch, and a survivor there is
     the #652 bug on the local side, not a benign leftover. Reporting it as a
     reassuring NOTE in both cases would tell the operator the one thing that
     hides the failure — a message must not assert a cause it did not verify.

     > **Why this block is prose and not a tested script.** It runs as the
     > agent's own live `gh`/`git` calls against a real PR, so there is nothing
     > for `tests/` to invoke — unlike `bash-guard.sh`, whose logic is a script
     > and is pinned by `validate-bash-guard-worktree.sh`. That is a real
     > tradeoff, not an oversight: a future edit that reorders the prune before
     > the state check, or drops the `-F` from the `grep`, would not fail any
     > test. Per this repo's convention for logic that cannot be exercised
     > in-session, the backstop is `docs/verification/` evidence from a live run
     > plus PR review. Treat edits here with the care that implies.

     The cleanup steps below run on **both** the clean-merge and the
     MERGED-after-cleanup-failure paths. Steps a and b hit the API, not the local
     tree, so a failed local checkout can never strand the label swap (the exact
     half-finish issue #225 reports):

     a. **Clear the in-flight status labels.** The merge has already landed by
     the time this step runs, so the `Closes #{N}` in the PR body is closing the
     issue right now — do **NOT** add `status/pr-pending` here. That label means
     "a PR exists and is awaiting merge"; on this path the wait is already over,
     so adding it would stamp a closed issue with a stale in-flight label that
     nothing later removes (#654). Remove both instead:

        ```bash
        gh issue edit {N} --remove-label "status/in-progress" --remove-label "status/pr-pending"
        ```

        ```bash
        # GitLab
        glab issue update {N} --unlabel "status/in-progress" --unlabel "status/pr-pending"
        ```

     The `status/pr-pending` removal covers a PR that picked the label up in an
     earlier parked cycle (a dead-end that a human later un-parked, or an L1–L2
     ship whose merge gate was crossed by hand). When the label was never
     applied this is a **clean no-op**: `gh issue edit --remove-label` exits 0
     for a label that exists in the repo but is absent from the issue, and only
     errors when the label does not exist in the **repo** at all (which is not
     this case — ship applies it on the L1–L2 path). No `|| true` guard is
     needed, and adding one would only mask a genuinely missing label.

     b. Comment on the issue:

        ```bash
        gh issue comment {N} --body "Fix merged in PR #{pr_number} (squash) after green CI + clean review."
        ```

     c. **Primary checkout only:** `git checkout main` (then `git pull` to
     fast-forward the merge). **Skip in a linked worktree** — its HEAD need not
     move and the golem worktree is torn down by `worktree-rm.sh`. This is the
     one step that genuinely turns on **session location**, so detect it here
     with the repo-standard idiom (`git rev-parse --git-dir` != `git rev-parse
     --git-common-dir` means a linked worktree; equal means the primary
     checkout) — the same check `hooks/golem-notify.sh` and
     `scripts/seed-worktree-trust.sh` use. Do **not** reuse it to decide
     `--delete-branch` above: that is a question about the branch, not the
     caller (#653).
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
   - **Review cycles**: {cycles} run (ceiling {REVIEW_MAX_CYCLES}); stopped on
     {deciding `rule` from review-convergence.sh, e.g. `C4-zero` or `C1-cap`}
   - **Review status**: {clean | stopped-with-blocking: {detail} | skipped: {reason}}
   - **Findings fixed**: {count} blocking, on this PR
   - **Findings deferred**: {#A, #B (filed), or "none"}
   - **Comments resolved-or-deferred**: {n}/{total}
   - **Deferred notes**: {drift / branch-freshness / pre-review findings, or "none"}
   - **Plan comment**: {plan_comment_url, if present}

   CI green + review clean. At L1–L2 the merge gate is a human's — ready for
   human merge. (An L3–L4 run would have auto-merged.)

   **After you merge:** remove `status/pr-pending` from #{N}. The squash
   commit's `Closes #{N}` closes the issue, but nothing takes the label off —
   ship has already exited by then (#654). `/workflow:golem --teardown {N}`
   does it for you on a golem run; finishing by hand means
   `gh issue edit {N} --remove-label "status/pr-pending"`
   (GitLab: `glab issue update {N} --unlabel "status/pr-pending"`).
   ```

   Then STOP — do not proceed to Step 5.

## Option 2 — Commit to main + push

**Review gate — check BEFORE the push (#637).** The adversarial review — the
**Workflow tool** with `ship-issue/workflow.js`, `args` keys and full block in
`pre-ship-validation.md` Step 3.5 b — runs on
Options 1, 2 and 3 alike (`pre-ship-validation.md` Step 3.5 item 6), so the
"a skipped review is not a clean review" invariant binds here too — and binds
*harder*, because this option has no PR to park: an ungated push puts unreviewed
code directly on `main`, where the only remedy is a revert. So if the review
ended `skipped: {reason}` or `stopped-with-blocking`:

- **Do NOT `git push origin main`.**
- **Fall back to Option 3** (commit only, no push): the commit is already made,
  so keep it local, label the issue `status/commit-pending`, and STOP for a
  human with the reason. Nothing is lost — a human can push or open a PR once
  the review has actually run.

Proceed with the steps below only when the review ran and came back `clean`.

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
