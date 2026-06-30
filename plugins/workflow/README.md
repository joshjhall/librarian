# workflow

Part of the [librarian](../../README.md) Claude Code plugin marketplace.

Issue-driven and parallel-automation workflow: pick the next issue, run the
autonomous pipeline, and fan work out across per-issue golems (one
issue/branch/worktree/PR each) — on a host, on bare Linux, or inside a
devcontainer.

## Skills (9)

- `file-issue` — structured GitHub/GitLab issue creation with auto-labeling
- `next-issue` / `next-issue-ship` — issue-driven development + delivery
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
| `seed-worktree-trust.sh` | Seed Claude Code workspace trust for a worktree |
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

The `GOLEM_*` vars above are sourced by the bundled shell scripts. The vars
below are **skill-level tunables** — read from the environment by the
`next-issue-ship` skill itself (not by any shell script), following the same
opt-in/override convention. They are documented in that skill's "Environment
Variables" section.

### Skill-level tunables (`next-issue-ship`)

This is a quick reference; the skill's "Environment Variables" section is
authoritative and documents the same vars in the same order.

| Variable | Default | Meaning |
| --- | --- | --- |
| `AUTOMERGE` | _unset_ | `1` queues the PR for GitHub native auto-merge on creation (skips the review loop) |
| `AUTOMERGE_AUTONOMOUS` | _unset_ | `1` is the required second consent for `AUTOMERGE` in autonomous runs |
| `PRE_REVIEW_STRICT` | _unset_ | `true` blocks PR creation on HIGH-certainty pre-review findings |
| `REVIEW_MAX_CYCLES` | `3` | Post-CI adversarial review threshold — caps review cycles (the review action's cut-short/extend lever) |
| `REVIEW_STRICT` | _unset_ | `true` treats MEDIUM-certainty review findings as blocking |
| `LIBRARIAN_CI_WAIT_TIMEOUT` | `15 min` | CI-wait threshold; at the checkpoint, prompt cut-short/extend (autonomous: auto-extend up to `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` times then stop) |
| `LIBRARIAN_CI_WAIT_MAX_EXTENSIONS` | `2` | Autonomous-only: extra `LIBRARIAN_CI_WAIT_TIMEOUT` intervals before giving up on pending CI (no hang) |
