---
name: path-guard-must-expand-before-scoping
description: "A guard that decides on a PATH must apply every shell expansion the shell would have applied BEFORE its absolute-vs-relative test — an unexpanded ~ became a nonexistent path, hit the -d check, and fail-opened, so the same worktree denied by absolute path and allowed by ~"
metadata:
  type: feedback
---

When a guard reads a path out of a payload and decides scope from it, it sees the
operand **as typed** — before the shell has expanded anything. Any expansion the
guard fails to reproduce turns a real target into a bogus one, and if the guard
then fail-opens on "path doesn't exist", the bogus path becomes a **silent
bypass**.

Concretely (#662, caught by the pre-PR review, confirmed by dynamic repro):

```text
git -C /home/me/wt/x reset --hard   -> DENY   (correct)
git -C ~/wt/x        reset --hard   -> ALLOW  (bypass — same worktree!)
```

`~/wt/x` is not absolute by a `case "$p" in /*)` test, so it was joined to cwd as
`<cwd>/~/wt/x`, which exists nowhere; the `[ -d "$target" ] || exit 0` fail-open
then allowed it. The guard was correct about *every* path it could resolve and
useless for the one an operator is most likely to type by hand.

**How to apply:** in any path-scoping guard, order the steps as
**expand → normalize → absolutize → scope**, and treat each expansion class
explicitly:

- `~` / `~/…` — expand from `$HOME` (guard `${HOME:-}` so an unset HOME
  fail-opens instead of aborting under `set -u`).
- `~user/…` — usually *not* worth expanding (needs a passwd lookup); let it
  fail open, but **say so** in the accepted-gaps list.
- `$var` / `$(…)` — genuinely unresolvable without evaluating the shell; fall
  back to cwd and document it.
- `.` / `..` / `//` / trailing `/` — collapse lexically before any prefix
  comparison, or `$WT/../x` walks straight out of scope. (`worktree-guard.sh`
  already does this; the sibling did not.)

**Why fail-open makes this worse, not safer:** fail-open is the right posture for
a guard that must never break the happy path — but it converts every *resolution*
bug into a *silent allow*. So the fail-open branches are exactly where to look
hardest, and each one deserves a test that proves it is reached for the intended
reason rather than by accident.

**Test shape that catches it:** assert the **same target** through **every
spelling** and require the decisions to agree, with the absolute form as an
explicit control in the same test — otherwise a bypass reads as "the sandbox was
wrong" rather than "the guard was wrong". Then mutate: remove the expansion and
confirm the fixture flips (see [[mutate-after-every-security-fixture]]).

Related: [[comment-asserts-intent-not-code]] — the header listed the targeting
forms it could not resolve, and `~` was not among them, so the doc read as
complete while the gap was live.
