# Worktree-Safe Recipes

On-demand companion for `next-issue/`, `ship-issue/`, and `golem/`. **Load this
before adding or editing a `bash` recipe in any of those three skills.**

It exists because the Claude Code Bash tool **refuses** a command it cannot
statically verify stays inside the worktree, once the session is
`EnterWorktree`-isolated. The refusal reads:

```text
This session is isolated in the worktree /…/.worktrees/issue-N, but this
command is too complex to verify that it stays inside the worktree.
```

A refused command is easy to miss: it looks like one stray denial line and the
run continues. That is the failure mode this file exists to prevent.

## Who is affected — isolation, not cwd

The trigger is the harness's **worktree-isolation state**, which
`EnterWorktree` sets. It is *not* keyed to the working directory.

| run shape | isolated? | affected |
| --- | --- | --- |
| `/workflow:golem`, Phase C onward | yes — Phase B calls `EnterWorktree` | **yes** |
| everything `/workflow:next-issue` runs inside that golem | yes — inherits the session | **yes** |
| everything `/workflow:ship-issue` runs when chained in-turn at L3–L4 | yes — same session | **yes** |
| detached tmux / container golem (`golem-launch.sh`) | no — cwd set by `tmux -c "$wt"` at launch | no |
| `/workflow:orchestrate` in the main checkout | no | no |
| `/workflow:golem` Phase A/B/D | no — run from the main checkout | no |

**This is the correction #815 made to #809.** #809 fixed `golem/SKILL.md` § Phase
C and recorded that it was "the only recipe that runs post-`EnterWorktree`". That
was false: Phase C *delegates* to `/workflow:next-issue`, which chains
`/workflow:ship-issue` in-turn, and all of it runs in the same isolated session.
The claim was asserted rather than measured — which is precisely why the row
above for the **detached** golem is stated with its mechanism (`tmux -c`), so the
next reader can check it instead of trusting it.

## What is refused — evaluability, not the presence of a `$`

Measured in an isolated session, deterministic across repeats:

| spelling | result |
| --- | --- |
| `echo hello` — pure literal | allowed |
| `/literal/path/script.sh --flag value` | allowed |
| `cycle=1; /literal/path/script.sh --arg "$cycle"` — inline-assigned | allowed |
| `echo "$HOME"` / `echo "$HOME/x.sh"` — unbraced `$HOME` | allowed |
| `echo "${HOME}"` — braced | **refused** |
| `echo "$PWD"`, `echo "$USER"`, `echo "$CLAUDE_PLUGIN_ROOT"` | **refused** |
| `${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh` | **refused** |
| `X=$(cmd); echo "$X"` — command substitution anywhere | **refused** |
| `/literal/path/script.sh --arg "$UNSET_VAR"` | **refused** |
| `mkdir -p d && cat > d/f <<'EOF' … EOF` — compound + heredoc | **refused** |

The operative property is whether the harness can **statically evaluate** the
command. A value it can see (a literal, a variable assigned in the same command,
`$HOME`) is fine; a value it cannot (a subshell's output, an env var it does not
model, a braced expansion) is not.

> **This table is harness-internal behavior, not a contract.** It was measured,
> not read off a spec, and a Claude Code release may change it. Treat it as the
> reason the two patterns below are shaped as they are — and if a recipe is
> refused despite matching an "allowed" row, trust the refusal and re-measure.

`CLAUDE_PLUGIN_ROOT` additionally is **not exported into the Bash environment**
at all (`env | grep -c CLAUDE_PLUGIN_ROOT` → 0), so that spelling has two
independent reasons to fail.

## Pattern 1 — run the script bare, read its `key=value` output

**Use this whenever the recipe's purpose is to get values back.** It is the fix
for the worst shape in the corpus, `eval "$(script …)"`:

```bash
# worktree-safe-exempt: this is the ANTI-EXAMPLE the section exists to show
# WRONG inside a worktree — the command substitution is refused, `eval` of a
# refused substitution yields an EMPTY STRING, and the variable silently stays
# unset. No error surfaces; the run just proceeds on a default.
eval "$(${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh level --chosen-level 3)"
```

Instead, run it with a literal path and **read** the output:

```bash
<skill-base-dir>/../../scripts/autonomy-resolve.sh level --chosen-level 3
```

It prints `key=value` lines (`autonomy_level=3`, `plan_gated=true`, …); take the
values from the output. This is the same division of labour `context-budget.sh`
already documents — the script owns the arithmetic, the model runtime performs
the action — and it is worktree-safe **by construction**, because no command
substitution remains to refuse.

Prefer this pattern over Pattern 2. Removing the `$(...)` requirement is more
robust than respelling a path, since it does not depend on the matrix above
staying true.

## Pattern 2 — substitute `<skill-base-dir>` with a literal

**Use this when the recipe genuinely needs a path to a bundled script.** Replace
`<skill-base-dir>` with the literal path from **this skill's own invocation
header** (`Base directory for this skill: …`), so the command contains only
literal text:

```bash
<skill-base-dir>/../../scripts/context-budget.sh check .
```

The invocation header is the only runtime-portable literal source: the install
root differs per host, so no path hardcoded in a file would be portable, and
`CLAUDE_PLUGIN_ROOT` is unavailable for the two reasons above.

`.` is safe as an argument — the isolated session's cwd is already the worktree,
and `context-budget.sh` normalizes a trailing `/.` before deriving its transcript
slug (#809).

> If a bundled script misbehaves under a literal `/opt/…` path but works from the
> repo copy, suspect a **stale install** before suspecting the script: an
> installed plugin can predate a fix in the tree.

## What is deliberately NOT rewritten

The `golem-status.sh`, `golem-attach.sh`, `golem-inbox.sh`, and
`golem-notify.sh` recipes in `escalation-protocol.md` and
`ci-review-protocol.md` keep their `${CLAUDE_PLUGIN_ROOT}` spelling. They are the
**detached-golem feed path** — run by the orchestrator or by a human in the main
checkout, per the table above — so they are not isolated and the refusal never
applies.

This is an exclusion by **stated reason**, checkable against the table's `tmux -c`
mechanism. It is not the "these do not exist" claim #809 made.

## The upstream fix

Exporting `CLAUDE_PLUGIN_ROOT` into the Bash environment would retire the
`${CLAUDE_PLUGIN_ROOT}`-half of this workaround entirely. That is a **Claude Code
harness** change, not a librarian one — noted so the next reader knows this file
documents a workaround with a known upstream resolution, not a permanent
convention.

## Enforcement

`tests/lint-worktree-recipes.sh` (run by `tests/run-all.sh`, so it gates CI and
pre-push) scans fenced `bash` blocks in the three affected skills and fails on a
refused spelling. Mark a deliberate exception with a
`# worktree-safe-exempt: <reason>` comment inside the block — a real reason,
checkable against the boundary table above, not a blanket suppression.

Two gaps the gate cannot close, both stated rather than left implicit:

- **Bare command substitution** (only the `eval "$(...)"` shape is flagged).
  A bare `$(...)` is genuinely refused too, but it fails *loudly* (the step
  stops) where the `eval` shape fails *silently*, and sweeping it would touch
  ~31 further recipes. Filed as **#819**.
- **Inline prose directives.** The gate scans fenced `bash` blocks only, so a
  sentence like *"Resolve the disposition with
  `${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh gate …`"* is invisible to
  it — yet it instructs an invocation just as a fenced block does. These span
  several scripts, not just `autonomy-resolve.sh`: `workflow-wall-timeout.sh`
  and `recover-journal-partials.sh` have them too. **Whenever you follow an
  inline `${CLAUDE_PLUGIN_ROOT}` reference inside a worktree, apply Pattern 1 or
  2 by hand** — the gate will not remind you.

  **Deliberately not enumerated here.** An earlier draft named a count and a
  file list; it was wrong within one review cycle, which is precisely how #809's
  false note came about. Distinguishing a directive from a discussion is a
  judgment a prose scanner cannot make, so instead of a census that rots,
  `tests/lint-worktree-recipes.sh` pins the inline **population** and fails when
  it grows — re-derive the current set with:

  ```bash
  # worktree-safe-exempt: a grep OVER the corpus, not a recipe that runs in one
  grep -rn '`${CLAUDE_PLUGIN_ROOT}' plugins/workflow/skills/{next-issue,ship-issue,golem}/
  ```

  Widening the fenced corpus to prose is not the fix: it would flag this very
  file, and every discussion of the rule — the self-contradiction the
  fenced-block scoping exists to avoid.
