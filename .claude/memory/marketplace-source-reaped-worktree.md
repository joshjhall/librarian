---
name: marketplace-source-reaped-worktree
description: "librarian marketplace can get registered against a golem WORKTREE path; reaping that worktree (post-merge) breaks the source → cache-miss → all librarian plugins fail to load → next dispatched golem is DOA (Unknown command: /workflow:next-issue). Fix: re-point marketplace to /workspace/librarian main checkout"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: de55e24b-986b-4be4-9eac-43fc9c6a1593
  modified: 2026-08-01T04:13:39.934Z
---

**Symptom:** a freshly-dispatched worktree golem comes up DOA with
`● Unknown command: /workflow:next-issue` / `● Args from unknown skill: N --level 3`
and idles at its prompt (no spinner). Earlier golems in the same batch worked
fine.

**Root cause:** `claude plugin marketplace list` showed the `librarian`
marketplace **Source: Directory (/workspace/librarian/.worktrees/issue-422)** — a
golem worktree that was REAPED when its PR merged. A prior session (or a
`claude plugin marketplace add` run from inside a worktree) had registered the
marketplace against that transient path. Once reaped, the source dir is gone →
`claude plugin list` shows `Error: Marketplace librarian failed to load:
cache-miss` for all three plugins → any golem session launched AFTER the reap
loads no workflow plugin and is DOA. Golems launched BEFORE the reap already had
the plugin resident, so they were unaffected — which is why only the newest
golem broke.

**Why:** the marketplace source must be a STABLE path. A worktree under
`.worktrees/issue-N` is by definition ephemeral (reaped on merge), so pointing
the marketplace there is a latent time-bomb that detonates on the next dispatch
after that specific worktree is reaped.

**How to apply:** (1) FIX = `claude plugin marketplace add /workspace/librarian`
(re-points Source to the stable main checkout; "Successfully added marketplace:
librarian"). Verify with `claude plugin marketplace list` (Source: Directory
(/workspace/librarian)) + `claude plugin list` (no cache-miss). (2) Then reap the
DOA golem (`tmux kill-session` + `worktree-rm.sh N` + rm cache) and RE-DISPATCH —
the fresh session loads the command. (3) PREVENT: never `marketplace add` from a
worktree cwd; always register librarian against the main checkout. (4) DIAGNOSE
cue: DOA "Unknown command" on a golem while siblings work = check
`marketplace list` Source FIRST (distinct from a USER-scope-not-enabled DOA,
which fails ALL golems, not just the newest).
