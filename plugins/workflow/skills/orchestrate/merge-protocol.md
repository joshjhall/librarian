# Orchestrate — Merge & Rebase Protocol

Reference companion for `SKILL.md`.

> **Topology note.** The default `/workflow:orchestrate` topology is PR-per-golem
> (`SKILL.md` Phases D/M/R). The **merge** and **sync** sections below are
> **OPT-IN LEGACY local-merge** — used only for tightly-coupled no-PR worktree
> work. The **Conflict Classification** and **Test Runner Detection** sections
> are **repurposed and remain live**: they drive the cross-PR rebase (Phase R,
> via `workflow.js` + the `rebase-agent`) as well as the legacy local merge.

Each section below is tagged **[LIVE]** (used by the default PR-per-golem flow)
or **[OPT-IN LEGACY]** (local-merge only).

---

## Legacy sections moved

Every **[OPT-IN LEGACY]** section of this protocol — sync-point tracking,
squash vs merge commit, the local-merge review and sync protocols, agent
checkpoint context, and the legacy local-merge phases — now lives in
**`merge-legacy.md`** in this directory (#973).

They apply only under the opt-in **local-merge** topology, where the
orchestrator merges golem branches itself. Under the default **PR-per-golem**
topology a golem ships its own PR and none of it runs, so this file keeps only
the three LIVE sections below.

Every moved section, linked so nothing is reachable only by memory:

- [Sync Point Tracking [OPT-IN LEGACY]](merge-legacy.md#sync-point-tracking-opt-in-legacy)
- [Squash vs Merge Commit [OPT-IN LEGACY]](merge-legacy.md#squash-vs-merge-commit-opt-in-legacy)
- [Review Protocol [OPT-IN LEGACY]](merge-legacy.md#review-protocol-opt-in-legacy)
- [Review Scope](merge-legacy.md#review-scope)
- [Agent Dispatch Order](merge-legacy.md#agent-dispatch-order)
- [Correction Commit Convention](merge-legacy.md#correction-commit-convention)
- [What NOT to Auto-Fix](merge-legacy.md#what-not-to-auto-fix)
- [Sync Protocol [OPT-IN LEGACY]](merge-legacy.md#sync-protocol-opt-in-legacy)
- [Sync Direction](merge-legacy.md#sync-direction)
- [Merge Order](merge-legacy.md#merge-order)
- [Conflict Handling](merge-legacy.md#conflict-handling)
- [Post-Sync Verification](merge-legacy.md#post-sync-verification)
- [Label Cleanup](merge-legacy.md#label-cleanup)
- [Return to Orchestrator](merge-legacy.md#return-to-orchestrator)
- [Agent Checkpoint Context [OPT-IN LEGACY]](merge-legacy.md#agent-checkpoint-context-opt-in-legacy)
- [Reading Agent Checkpoints](merge-legacy.md#reading-agent-checkpoints)
- [Using Checkpoint in Review](merge-legacy.md#using-checkpoint-in-review)
- [Local-Merge (OPT-IN, Legacy)](merge-legacy.md#local-merge-opt-in-legacy)
- [Merge (legacy Phase 2)](merge-legacy.md#merge-legacy-phase-2)
- [Review (legacy Phase 3)](merge-legacy.md#review-legacy-phase-3)
- [Sync (legacy Phase 4)](merge-legacy.md#sync-legacy-phase-4)

## Conflict Classification for Cross-PR Rebase [LIVE]

This decision tree is the source of the `workflow.js` conflict-class taxonomy
(the `OVERLAP` gate and the `rebase-agent`'s `resolved`/`escalated` split) used
in Phase R, and it also governs legacy local-merge conflicts.

**Execution context (Phase R).** Every cross-PR rebase runs **inside the PR's
own worktree** — the `<worktree>` path Phase R resolves (`git worktree list`)
and passes to the harness. The `rebase-agent` `cd`s into it and never runs
`git checkout`/rebase in the orchestrator's **root** working tree, which is the
live human session's checkout. A PR whose branch has no resolvable worktree is
**escalated** as a whole-PR manual review (`no resolvable worktree context`),
never rebased against an improvised checkout (#268).

When a PR branch is behind base and a rebase onto base reports conflicts (or
when `git merge` reports conflicts in the legacy path):

1. **Identify conflict type** for each file:

   ```bash
   git diff --name-only --diff-filter=U
   ```

1. **For each conflicted file**, examine the conflict:

   ```bash
   git diff <file>
   ```

1. **Resolution strategy by conflict type**:

   Trivial conflicts can be auto-resolved by dispatching the `rebase-agent`:

   | Conflict Type                        | Action                                                      | Agent                           |
   | ------------------------------------ | ----------------------------------------------------------- | ------------------------------- |
   | Lock files (package-lock, etc)       | Regenerate: accept one side, re-run package manager         | rebase-agent (rebase-lockfile)  |
   | Generated files (\*.pb.go, etc)      | Accept one side, re-run generator                           | rebase-agent (rebase-generated) |
   | Both sides added imports             | Combine both import sets, deduplicate, sort                 | rebase-agent (rebase-imports)   |
   | Composable same-region edits         | **Union** both sides — keep the superset of every change    | rebase-agent (union)            |
   | Version number conflicts             | Take the higher version                                     | rebase-agent (rebase-version)   |
   | Whitespace / formatting only         | Accept agent's version (`git checkout --theirs <file>`)     | rebase-agent                    |
   | Same region, **contradictory** edits | **Escalate** — show both versions to user, ask for guidance | (human)                         |
   | New file vs new file                 | **Escalate** — show both, ask user                          | (human)                         |
   | Deletion vs modification             | **Escalate** — ask user                                     | (human)                         |

   **Composability triage — try union before escalating.** "Both sides touched
   the same region" is not automatically an escalation. Before flagging a
   same-region conflict for a human, classify the *intent* of the two edits:

   1. **Composable** — each side adds a distinct, non-contradictory change to the
      same construct (a new flag/arg/clause, an adjacent additive edit) →
      **union**: keep the superset of both sides. This is the general form of the
      "both added imports → combine" rule above; the import case is just the
      special case where the construct is an import block.
   1. **Mutually exclusive** — both sides set the *same* value/token to different
      things with conflicting intent (e.g. two different version bumps, two
      different timeouts) → accept one side per the per-type rules above
      (e.g. higher version).
   1. **Semantically contradictory** — reconciling the two edits needs judgment
      about intent (overlapping logic changes that can't simply coexist) →
      **escalate** to the human.

   Union is the **default** for same-region edits whose intents don't conflict;
   escalation is the fallback, not the first move. Only genuinely contradictory
   edits (case 3) go to a human.

   **Worked example (the #585/#586/#587 launch-line union).** Three parallel
   golems each edited the same `worktree-new` launch line: #585 added
   `--permission-mode auto` plus the `/workflow:ship-issue` chain, and #587 added
   `-e GOLEM_ID=golem-{N}`. These are additive and composable — none overwrites
   another's change — so the correct resolution is the **union** of all three:

   ```text
   ... -e GOLEM_ID=golem-{N} "claude --permission-mode auto '/workflow:next-issue ...' ; claude --permission-mode auto '/workflow:ship-issue ...'"
   ```

   The old "same region → escalate" reading would have forced a needless human
   round-trip for a merge that is mechanically unionable.

   To dispatch the rebase-agent for trivial conflicts:

   ```text
   Agent tool: rebase-agent
   Prompt: "Resolve the following merge conflicts. Conflicted files: {file_list}.
   For each file, classify the conflict and apply the appropriate strategy. When
   both sides touched the same region, attempt a union of complementary,
   non-contradictory edits (keep the superset of both) before escalating.
   Escalate only genuinely contradictory conflicts."
   ```

1. **After resolving all conflicts**:

   ```bash
   git add <resolved-files>
   git commit  # Completes the merge
   ```

1. **If conflicts are too complex**: Abort and suggest alternative:

   ```bash
   git merge --abort
   ```

   Suggest cherry-picking specific commits instead, or ask the user to
   manually resolve.

---

## Integration Train — Sequencing & CI-Subset Policy [LIVE]

Drives `SKILL.md` **Phase T**: landing a batch of already-green, already-approved
PRs end-to-end (merge → rebase the next → merge) with **one** up-front
authorization instead of one human gate per step, and with CI re-run cost
bounded. The train adds **sequencing** and a **CI-cost policy** on top of the
existing pieces — the order is computed by `workflow.js` (`mode: 'train'`), each
rebase is the **Conflict Classification** flow above (Phase R), and every
outward action still passes the live session's `ask` gates. The harness itself
never merges and never pushes.

### Merge-order from file-overlap

The merge order is derived **purely from pairwise changed-file overlap** — two
PRs that share at least one changed file must be landed in sequence (each rebased
onto the prior merge); two PRs that share none are independent and land in any
order with no rebase between them.

`workflow.js` (`mode: 'train'`) computes this as a connected-components graph over
the PRs (edge = shared changed file) and returns:

| Field          | Meaning                                                                    | Landing rule                                   |
| -------------- | -------------------------------------------------------------------------- | ---------------------------------------------- |
| `independents` | PRs sharing no changed file with any other                                 | Merge in any order, **no rebase**              |
| `chains`       | Overlap components of ≥2 PRs (touch a common file), each ordered by number | Merge **in sequence**, rebase each onto prior  |
| `waves`        | Parallelizable batches: wave 0 = independents + chain heads; wave *k* = *k*-th chain link | Merge a whole wave, then advance               |
| `order`        | One conservative linear order (independents, then chains laid out in full) | Fallback when you just want a flat list        |

Feed the harness each PR's `files` (from `gh pr view <N> --json files`); a PR
whose list is omitted is fetched with a read-only poll, or treated as
no-overlap if the budget is exhausted (conservative — it just lands independently).

### The merge → rebase → merge loop

1. **Wave 0** — merge every independent and every chain head. These are already
   green and need no rebase, so they land without re-triggering CI.
1. **Advance each chain by one link** — once a chain's current head merges, its
   next link is behind base. Run Phase R (`mode: 'poll+rebase'`) scoped to that
   PR to rebase it onto the new base, applying the union strategy from Conflict
   Classification (only genuinely contradictory conflicts escalate).
1. **Push** the rebased branch (`git push --force-with-lease origin <branch>` —
   the harness never pushes) and **merge** it.
1. **Repeat** wave by wave until the batch is drained. Loop-until-dry and
   resumable: re-poll between waves to confirm CI stayed green and catch any
   newly-behind PR.

### CI-subset policy

A force-push after a rebase normally replays the **full** build matrix on the
next branch — the dominant cost when landing N overlapping PRs. Bound it, **where
the repo's branch protection permits**:

- **Prefer `gh pr merge --auto`** (`--squash --delete-branch`) so GitHub merges
  each PR the moment its already-green checks settle, instead of a manual merge
  followed by a wait. Independents and no-conflict rebases then add no full
  replay.
- **Changed-file check subset.** For a rebase whose only conflicts were
  docs/skills-only and were union-resolved (per Conflict Classification),
  require only the **changed-file** check subset to re-pass rather than the whole
  matrix. This is a per-repo policy choice — apply it only where branch
  protection allows a reduced required-check set; otherwise fall back to the full
  matrix.
- **Parallelize independents.** Only the overlapping chain is serialized; the
  independent PRs (wave 0) land concurrently, not behind each other.

Merging is the level-aware routine gate (auto at L3–L4 after green CI + clean
review; human-authorized at L1–L2 — see `orchestrate/autonomy-levels.md`). The
train's single batch approval authorizes the *sequence*; it does **not** override
the per-PR merge invariant (green CI + clean review).

### Worked example (the #585/#586/#587 + independents batch)

Five green PRs: #585/#586/#587 each edited the same
`orchestrate/mode-protocol.md` launch line (overlap), while #590 and #591 touched
unrelated files. The train computes:

```text
independents: [590, 591]
chains:       [[585, 586, 587]]
waves:        [[585, 590, 591], [586], [587]]
order:        [590, 591, 585, 586, 587]
```

Wave 0 lands #590, #591, and chain head #585 in parallel (no rebase). Wave 1
rebases #586 onto the new base (the #585 launch-line edit is union-resolved per
Conflict Classification — additive, non-contradictory) and merges it; wave 2 does
the same for #587. The old by-hand flow needed ~6 authorizations + 3 full CI
replays for the chain alone; the train needs **one** batch approval, serializes
only the 3-PR chain, and bounds each rebase's CI to the settle/subset policy
above.

---

## Test Runner Detection [LIVE]

Topology-neutral. Used after a cross-PR rebase (Phase R) to confirm the rebased
branch still builds, and after a legacy local merge. Detect and run the
project's test suite, checking in this order (first match wins):

| Indicator                | Test Command            | Framework   |
| ------------------------ | ----------------------- | ----------- |
| `package.json` (test)    | `npm test`              | Node/JS     |
| `pyproject.toml`         | `pytest`                | Python      |
| `setup.py` or `tox.ini`  | `pytest`                | Python      |
| `go.mod`                 | `go test ./...`         | Go          |
| `Cargo.toml`             | `cargo test`            | Rust        |
| `Gemfile`                | `bundle exec rake test` | Ruby        |
| `Package.swift`          | `swift test`            | Swift/SwiftPM |
| `Makefile` (test target) | `make test`             | Generic     |
| `build.gradle`           | `./gradlew test`        | Java/Kotlin |

**Detection logic:**

```bash
# Check for package.json with test script
if [ -f package.json ] && /usr/bin/grep -q '"test"' package.json; then
    npm test
# Check for Python project
elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f tox.ini ]; then
    pytest
# Check for Go module
elif [ -f go.mod ]; then
    go test ./...
# Check for Rust project
elif [ -f Cargo.toml ]; then
    cargo test
# Check for Ruby project
elif [ -f Gemfile ]; then
    bundle exec rake test
# Check for Swift Package Manager project
elif [ -f Package.swift ]; then
    swift test
# Check for Makefile with test target
elif [ -f Makefile ] && /usr/bin/grep -q '^test:' Makefile; then
    make test
# Check for Gradle project
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
    ./gradlew test
fi
```

If no test runner is detected, inform the user and skip testing.

---
