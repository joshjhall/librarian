---
name: tmux-private-server-must-be-addressed-by-socket-path
description: A missing TMUX_TMPDIR silently falls back to the shared default tmux server, and $TMUX outranks it inside a golem; a "sandboxed" kill-server then kills every live golem — address a private server by -S socket path
type: feedback
stale_check: "tmux behavior is version-specific (measured on 3.5a): re-run `TMUX='' TMUX_TMPDIR=/nonexistent tmux new-session -d -s probe 'sleep 20'; tmux ls` and see whether probe lands on the default server"
---

`TMUX_TMPDIR` pointing at a directory that does **not exist** is not an error:
tmux 3.5a silently falls back to the default socket dir
(`/tmp/tmux-<uid>/default`) — the shared server every golem runs on. Reproduced:
`TMUX='' TMUX_TMPDIR=/nonexistent tmux new-session -d -s probe 'sleep 20'`
exited 0 and `probe` appeared in plain `tmux ls`.

Separately, inside a golem `$TMUX` names the shared server and **outranks**
`TMUX_TMPDIR`, so a `TMUX_TMPDIR`-scoped command without `TMUX=` reaches the
shared server too.

Both routes fired in one orchestrate run, each running `kill-server` against the
shared server and killing every live golem on the host:

1. A test cleanup, `TMUX_TMPDIR="$dir" tmux kill-server`, with no `TMUX=`.
2. A hand-run probe, `T=$(mktemp -d); TMUX='' TMUX_TMPDIR="$T/.tmux" tmux …
   kill-server` — `mktemp -d` creates `$T` but not `$T/.tmux`, so it fell back.

**Why:** the failure is silent and the blast radius is the whole host — exit 0,
no warning, and a destructive command lands on a server the author never meant
to touch. Forgetting `TMUX=` and forgetting `mkdir` are both ordinary slips, so
the idiom has to make them impossible rather than rely on remembering.

**How to apply:** address a private server by explicit socket PATH, and prove the
socket exists before anything destructive:

```bash
[ -S "$sock" ] && TMUX='' tmux -S "$sock" kill-server
```

- `-S "$sock"` and `-L <name>` are both safe; always clear `TMUX`.
- Assert `[ -S "$sock" ]` as a control first — if the server never started, the
  destructive command must not run at all.
- Use `TMUX_TMPDIR` only if you `mkdir -p` it **and** verify it exists. The
  `new_sandbox` helper in `tests/lib/golem-sandbox.sh` is safe because it always
  creates `SANDBOX_TMUX_DIR`; the trap is a new or hand-written `TMUX_TMPDIR`
  whose directory may not exist.
- Never run `kill-server` against anything you did not address by `-S`/`-L`.

Worked example: `tests/golem-scripts/12-launch-auth.sh`. Related:
[confirm-pid-ownership-before-killing](confirm-pid-ownership-before-killing.md)
(same class — a kill aimed at something shared),
[worktree-new-seeds-home-claude-json](worktree-new-seeds-home-claude-json.md)
(its tmux sibling note recommends `TMUX_TMPDIR` for read-only `tmux ls` — safe
only while the directory exists),
[golem-gate-watch-host-leak](golem-gate-watch-host-leak.md) (the same shared
server, leaking from the read side), and
[env-scrub-absence-hides-a-path-stub](env-scrub-absence-hides-a-path-stub.md)
(an isolation knob that silently does not isolate).
