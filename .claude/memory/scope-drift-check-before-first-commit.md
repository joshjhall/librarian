---
name: scope-drift-check-before-first-commit
description: "Review's scope-drift detection is unreliable run-to-run — it caught memory-notes-on-a-code-PR on #542 and missed the identical thing across 5 cycles on #498; check git status BEFORE the first commit, never delegate it"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87b555fb-8e69-4c75-98f3-66c34a760396
  modified: 2026-07-30T10:05:09.396Z
---

**The gap.** The `/workflow:ship-issue` review harness has a scope-drift
dimension. On **#542 cycle 3** it caught memory notes riding along on a ruff-pin
PR (HIGH/0.8) and I split them to PR #577. On **#498** the identical defect —
`.claude/memory/MEMORY.md` plus a note quietly carried by commit `a4c1d5b`, whose
message never mentioned them — survived **five consecutive cycles** that found
eleven other real findings. I found it myself, and only incidentally: inspecting
the per-agent journal to verify cycle 5's zero was genuine, the first agent's file
list showed the `.claude/` paths.

So scope-drift detection is **not reliable run-to-run**. Same defect class, same
repo, one issue later, opposite outcome. It is a bonus when it fires, not a
control you can lean on.

**Why the timing matters.** I had already recorded the #542 instance as a memory
note — and repeated the mistake anyway. The note said to watch for it at review
time, which is too late: by then the file is in a commit, the commit message
doesn't mention it, and unwinding costs a rebase (I attempted one on #498, hit a
conflict in the file five cycles had just hardened, and aborted). The check has to
happen **before the first commit**.

**How to apply.** Before `git add`, run `git status --short` and ask of every
path: *does this belong to the issue in the branch name?* Notes, scratch files,
and unrelated docs get their own branch **first**, not a later split. After
committing, `git diff --name-only origin/main...HEAD` is the audit — but treat a
surprise there as a process failure, not a catch.

**If drift already landed and the PR squash-merges**, prefer a removal commit over
a history rewrite: only the final tree ends up on `main`, so `git rm` + a commit
explaining the descope reaches the same result with no risk of mangling the real
work. Verify the restored file is byte-identical to main
(`git diff --cached origin/main -- <path>`), and confirm the PR diff is clean
(`git diff --name-only origin/main...HEAD`).

Related: [[umbrella-issue-closes-vs-contributes]] (scope discipline at the issue
level), [[blocking-empty-is-not-nothing-to-fix]] (the other thing a clean cycle
does not prove), [[comment-asserts-intent-not-code]] (the other defect class I
recorded and then repeated).
