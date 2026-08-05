---
name: path-guard-must-expand-before-scoping
description: "A guard that decides on a PATH must reconstruct the FULL path the shell would have used — every expansion AND the cwd context (-C/cd) a relative operand resolves against — before its absolute-vs-relative test; get either wrong and it scopes a different directory than the command touches, then fail-opens into a silent bypass"
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

**The same class recurs whenever the guard drops PART of the path** — expansion
is only one way to get an incomplete one. #665 (PR #677, cycle-1 BLOCKING)
repeated it with the missing piece being the **cwd context** instead of an
expansion: a new arm read a worktree path from a *positional* operand and used it
as the target directly, discarding the `-C`/`cd` the same command had already
established. git resolves a relative operand against its effective cwd, so
`cd <peer-wt> && git worktree remove --force .` deleted the peer worktree while
the guard resolved `.` against the *session's* cwd, saw the primary checkout, and
allowed it.

Worth separating two failure modes that look alike:

- **Fail-open** — the guard cannot resolve the target, declines to decide, and
  allows. Deliberate, documented, acceptable.
- **Fail-wrong** — the guard resolves *confidently* to a **different** directory
  than the command touches. Reads like fail-open in the code (same `-d` check,
  same allow) but is strictly worse: no gap list will mention it, because the
  author believed the path resolved.

A guard mixing targeting styles is the high-risk shape: three verbs took `-C`, so
the helper that owned the `-C`/`cd` chain was reused everywhere — then a fourth
verb took its target positionally, the helper looked inapplicable, and the
context was silently dropped. **When a new operand style joins an existing guard,
the question is not "does the old helper apply?" but "which parts of the path
does the old helper still own?"**

**How to apply:** in any path-scoping guard, order the steps as
**expand → join to the effective cwd → normalize → absolutize → scope**, and
treat each expansion class explicitly:

- `~` / `~/…` — expand from `$HOME` (guard `${HOME:-}` so an unset HOME
  fail-opens instead of aborting under `set -u`).
- `~user/…` — usually *not* worth expanding (needs a passwd lookup); let it
  fail open, but **say so** in the accepted-gaps list.
- `$var` / `$(…)` — genuinely unresolvable without evaluating the shell; fall
  back to cwd and document it.
- `.` / `..` / `//` / trailing `/` — collapse lexically before any prefix
  comparison, or `$WT/../x` walks straight out of scope. (`worktree-guard.sh`
  already does this; the sibling did not.) Note `.` and `..` are also the
  operands that make a dropped cwd-context bug *reachable* — they are meaningless
  without the base, so they are the first shapes to test.
- **relative anything** — join onto whatever moved the effective cwd (`-C`, a
  preceding `cd`, `--git-dir`/`--work-tree`), chaining repeats the way successive
  chdirs do, and let an absolute operand reset the chain.

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

"Every spelling" means the **cross product**, not a list: absolute × relative ×
`.`/`..` × `~` × quoted × `-C`-based × `cd`-based. Both bugs in this family hid
in a *combination* whose parts were each individually covered — #665 tested
relative paths and tested `-C`, never relative-**with**-`-C`. Make the mutant
target the specific join, and require the absolute form NOT to flip: if it
flips too, the fixture is measuring the whole rule rather than the join.

**Do not trust a live-probe pass as coverage of the class.** A hand-probe of that
worktree-remove arm passed 14/14 and the suite passed 78/78 — every case used an
absolute path, because that is what one reaches for when writing probes by hand.
The review found the bypass in the shape nobody had typed.

Related: [[comment-asserts-intent-not-code]] — the header listed the targeting
forms it could not resolve, and `~` was not among them, so the doc read as
complete while the gap was live.
