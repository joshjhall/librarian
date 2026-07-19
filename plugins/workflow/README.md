# workflow

Part of the [librarian](../../README.md) Claude Code plugin marketplace.

Issue-driven and parallel-automation workflow: pick the next issue, run the
`/next-issue` → `/ship-issue` pipeline at a chosen **autonomy level** (L1–L4),
and fan work out across per-issue golems (one issue/branch/worktree/PR each) — on
a host, on bare Linux, or inside a devcontainer.

The autonomy level is the single dial for how much the pipeline decides on its
own: routine gates (push, PR-open, merge-on-green, prune) auto-pass at L3–L4 and
ask at L1–L2; escalation gates (plan approval, a mid-flight fork, a dead-end)
auto-pass at L4 only. It is set with `--level {1,2,3,4}` (the sole autonomy dial;
the old `--autonomous` / `--auto` / `NEXT_ISSUE_AUTONOMOUS` aliases were removed
in #215), and `severity/critical` issues cap at L3. A human gate is never timed
out — it waits indefinitely. See
[`skills/orchestrate/autonomy-levels.md`](skills/orchestrate/autonomy-levels.md)
for the authoritative model.

## First-run setup: authorize golem launch permissions

`/orchestrate dispatch` launches each worktree golem with a bare
`tmux new-session`. The Claude Code auto-mode classifier **denies** that shape
(`[Create Unsafe Agents]`) until the launch rules are authorized — so on a fresh
host the _first_ dispatch fails at an opaque wall before you ever see the
remediation that `golem-launch.sh preflight` would print. Authorize the three
rules once, before your first dispatch, by adding them to `permissions.allow`:

```jsonc
// in one settings scope's "permissions": { "allow": [ … ] }
"Bash(tmux new-session:*)",
"Bash(tmux ls:*)",
"Bash(tmux kill-session:*)"
```

Pick **one** scope:

- **project-local** — `.claude/settings.local.json` (this repo only)
- **global** — `~/.claude/settings.json` (all repos on this host)

Verify the rules are live in either scope with the bundled self-check:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/golem-launch.sh preflight
```

It is a no-op when the rules are present and prints the exact rules + scope
choice (exit 3) when they are missing. The plugin never writes these for you —
adding settings is itself permission-gated, so the flow is _suggest + ask, never
write silently_.

**The allow-list does not preempt the classifier (#282).** Authorizing these
rules removes the _allow-list_ denial, but the auto-mode **safety classifier**
(`[Create Unsafe Agents]`) is a **separate gate** that re-evaluates each
`tmux new-session` launch on its own judgment — and it is **non-deterministic**
on this launch shape (the same command can be denied once and approved on
immediate retry). So preflight passing is necessary, not sufficient: if a launch
is still denied with `[Create Unsafe Agents]`, **retry the identical command**
(it typically passes) rather than reaching for a manual paste.

**Why this is a manual step:** a Claude Code plugin's bundled `settings.json`
can only carry the `agent` / `subagentStatusLine` keys, not `permissions.allow`,
so the launch rules must live in a user- or project-level scope. **Devcontainer
users get them automatically** — the `containers` image seeds them into the
default `~/.claude/settings.json` (see
[joshjhall/containers#682](https://github.com/joshjhall/containers/issues/682)),
so this manual step is only for host / bare-Linux installs.

## Skills (9)

- `file-issue` — structured GitHub/GitLab issue creation with auto-labeling
- `next-issue` / `ship-issue` — issue-driven development + delivery
- `orchestrate` — master orchestrator for PR-per-golem parallel work
- `provision-agent` — provision headless agent containers (assumes a
  devcontainer-based setup; see its `SKILL.md`)
- `rebase-generated` / `rebase-imports` / `rebase-lockfile` / `rebase-version`
  — targeted merge-conflict resolvers

## Agents (3)

`issue-filer`, `ci-fixer`, `rebase-agent`.

(The `issue-writer` agent lives in the
[review-audit](../review-audit/README.md) plugin.)

## Hook

- `hooks/golem-notify.sh` — Notification hook that records each golem's
  permission-gate / idle transitions to the central status feed.

## Bundled scripts (`scripts/`)

The golem/worktree flow runs **without `just`** — these standalone scripts
replace the containers justfile recipes the skills used to call. Skills invoke
them as `${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh`.

| Script | Purpose |
| --- | --- |
| `worktree-new.sh <N>` | Create a push-ready worktree + branch for issue N |
| `worktree-rm.sh <N>` | Remove issue N's worktree + branch |
| `golem-status.sh` | Central golem status table + BLOCKED list (TTY-free) |
| `golem-attach.sh <N>` | Attach to issue N's golem (worktree tmux or container) |
| `golem-watch.sh` | Stream proactive gate notifications until Ctrl-C |
| `golem-gate-watch.sh` | Gate-detection engine shared by status + watch |
| `golem-token-scrape.sh <worktree>` | Scrape a Mode-2 golem's top-level token count from its newest transcript (deduped by `message.id`), feeding `golem-status.sh`'s frozen-counter signal (#371) |
| `seed-worktree-trust.sh` | Seed Claude Code workspace trust for a worktree |
| `recover-journal-partials.sh <journal>` | Recover finding-shaped partials from a `TaskStop`-ped review harness's `journal.jsonl` (#224) |
| `config.sh` | Shared env-overridable config + `repo_root` helper (sourced) |

### Configuration (env-overridable; defaults in `scripts/config.sh`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `GOLEM_WORKTREE_DIR` | `.worktrees` | Per-issue worktree directory |
| `GOLEM_STATUS_DIR` | `<worktree-dir>/.status` | Golem status JSON + feed |
| `GOLEM_BRANCH_PREFIX` | `feature/issue-` | Branch for issue N is `<prefix><N>` |
| `GOLEM_BASE_REF` | `origin/main` | Ref new worktree branches fork from |
| `GOLEM_WORKTREE_LOCAL_FILES` | `.env .claude/settings.local.json` | Gitignored files copied into a fresh worktree |
| `GOLEM_BLOCK_TTL` | `3600` | Feed gate-freshness window (seconds) |
| `GOLEM_WATCH_INTERVAL` | `5` | `--stream*` poll interval (seconds) |
| `CLAUDE_PROJECTS_DIR` | `$HOME/.claude/projects` | Base dir of per-project session transcripts; `golem-token-scrape.sh` resolves a golem's transcript under it |

The `GOLEM_*` vars above are sourced by the bundled shell scripts. The vars
below are **skill-level tunables** — read from the environment by the
`ship-issue` skill itself (not by any shell script), following the same
opt-in/override convention. They are documented in that skill's "Environment
Variables" section.

### Skill-level tunables (`ship-issue`)

This is a quick reference; the skill's "Environment Variables" section is
authoritative and documents the same vars in the same order.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PRE_REVIEW_STRICT` | _unset_ | `true` blocks PR creation on HIGH-certainty pre-review findings |
| `REVIEW_MAX_CYCLES` | `3` | Post-CI adversarial review threshold — caps review cycles (the review action's cut-short/extend lever) |
| `REVIEW_STRICT` | _unset_ | `true` treats MEDIUM-certainty review findings as blocking |
| `LIBRARIAN_CI_WAIT_TIMEOUT` | `15 min` | CI-wait threshold; at the checkpoint, prompt cut-short/extend (at L3–L4: auto-extend up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` times then stop). A machine timer for _pending CI_, not a human gate — the never-time-out rule governs human gates, not this bounded wait |
| `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` | `2` | L3–L4 only: extra `LIBRARIAN_CI_WAIT_TIMEOUT` intervals before giving up on pending CI (no hang) |
| `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` | `20 min` | Max wall-time for a single `Workflow` invocation (review fan-out, `ci-fixer`) before a checkpoint; at L3–L4 auto-extend up to `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` then `TaskStop` and proceed with recovered partials. Bounds a spinning agent the token budget can't (#224); a timed-out cycle is partial, never `clean` |
| `LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS` | `1` | L3–L4 only: extra `LIBRARIAN_WORKFLOW_WALL_TIMEOUT` intervals a hung `Workflow` invocation gets before it is stopped (no hang) |
