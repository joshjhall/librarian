---
name: worktree-new-seeds-home-claude-json
description: worktree-new.sh transitively writes $HOME/.claude.json via seed-worktree-trust.sh — sandbox tests must override HOME
metadata:
  node_type: memory
  type: project
  originSessionId: cb7e902b-3277-40ab-9087-9b9e306dc5b0
---

`plugins/workflow/scripts/worktree-new.sh` calls `seed-worktree-trust.sh "$root/$wt"`
at the end (best-effort trust seed). `seed-worktree-trust.sh`'s config target
**defaults to `$HOME/.claude.json`** (`cfg="${2:-$HOME/.claude.json}"`), and the
path-validation passes because the sandbox IS the repo root.

**Why:** A `worktree-new.sh` test run in an mktemp+git sandbox will write a real
trust entry (`.projects["<sandbox>/.worktrees/issue-N"]`) into the operator's
actual `~/.claude.json` unless `HOME` is overridden.

**How to apply:** In any test invoking `worktree-new.sh`, set `HOME="$sandbox"`
(and `GOLEM_WORKTREE_LOCAL_FILES=""` to skip the local-file copy) so the seed
write lands in a throwaway config. See [[devcontainer-bash-env-path-reset]] for
the sibling PATH-stub gotcha. Related: [[flaky-golem-gate-watch-test]] GIT_SCRUB
hermeticity.

**Sibling gotcha — tmux isolation:** `golem-status.sh` / `golem-attach.sh` /
golem-gate-watch pane modes run `tmux ls`, which hits the host's REAL tmux
server and sees live `golem-*` sessions (incl. the agent's own). Sandbox tests
must point `TMUX_TMPDIR="$sandbox/.tmux"` (+ `TMUX=`) at an empty per-sandbox
socket dir so `tmux ls` finds no server — otherwise the empty-state /
no-session assertions flake against whatever golems happen to be running. Both
overrides are in `tests/validate-golem-scripts.sh` `run_in` (issue #82).
