# worktree-rm.sh stale-symlink carve-out — end-to-end verification (#768)

**Status:** OPEN — awaiting the post-merge run against the live fixture.

## Why this file exists

The bug this fixes is a **filesystem** property, not a git or script property: on
a macOS Docker bind mount (virtiofs/bindfs) a committed symlink reports
`nlink=0 size=0`, which defeats git's stat comparison so git marks the link `M`
forever. That cannot be reproduced on the ext4 filesystem CI runs on — verified
during implementation:

- a committed symlink here reports `nlink=1 size=10` and stays clean
- `git update-index --cacheinfo`, a retarget-and-restore, and
  `core.checkStat minimal` all fail to manufacture it
- more sharply: on a sane filesystem an unstaged ` M ` symlink whose target
  matches the index is a **contradiction**, so the carve-out's positive arm has
  no natural fixture

`tests/golem-scripts/40-worktree-rm.sh` therefore drives the positive arm through
a `git` PATH stub that replays the `--raw` line **actually observed** on the live
`.worktrees/issue-760` worktree, while `cat-file`/`readlink` and all the decision
logic run for real. That is a faithful unit-level proof, but it is not the same
as tearing down a genuinely stale worktree.

This file records that missing half.

## The live fixture

`.worktrees/issue-760` is deliberately **kept** (it is the worktree whose blocked
teardown motivated this issue). It reproduces the condition:

```console
$ git -C .worktrees/issue-760 status --porcelain --ignore-submodules=all
 M .codegraph
 M AGENTS.md

$ git -C .worktrees/issue-760 diff --raw AGENTS.md .codegraph
:120000 120000 5223462 0000000 M	.codegraph
:120000 120000 681311e 0000000 M	AGENTS.md

$ git cat-file -p 681311e     # CLAUDE.md
$ readlink AGENTS.md          # CLAUDE.md
```

Index blob and on-disk target match on both paths, so both are stat artifacts and
neither is real work.

## Procedure (run after this PR merges to main)

From the **main checkout**, on merged `main`:

```bash
git -C /workspace/librarian log --oneline -1
/workspace/librarian/plugins/workflow/scripts/worktree-rm.sh 760
```

## Expected

- exit 0
- stdout contains `removed worktree .worktrees/issue-760 (forced past 2 stale
  symlink attr(s))` — the count is **2** (`AGENTS.md` and `.codegraph`)
- `.worktrees/issue-760` is gone; `feature/issue-760` local branch deleted
- no `has uncommitted changes` refusal

## Result

_Not yet run — fill in with the verbatim transcript once this lands on main._

## Note on scope

A pass here proves the carve-out fires on genuinely stale attributes. The
**negative** direction (real work still blocks) is covered by the suite and does
not need this fixture:

| Case | Where covered |
| --- | --- |
| retargeted symlink still blocks | `test_worktree_rm_refuses_genuinely_retargeted_symlink` |
| dirty regular file still blocks | `test_worktree_rm_refuses_dirty_regular_file_beside_symlink` |
| deleted symlink still blocks | `test_worktree_rm_refuses_deleted_symlink` |
| file replaced by symlink blocks | `test_worktree_rm_refuses_file_replaced_by_symlink` |
| clean teardown makes no false claim | `test_worktree_rm_clean_teardown_has_no_symlink_disclosure` |
