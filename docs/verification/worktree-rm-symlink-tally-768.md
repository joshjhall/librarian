# worktree-rm.sh stale-symlink carve-out — live-fixture tally (#768)

**Status: OPEN — the automated proof is complete and shipped; this file holds the
one check CI structurally cannot run,** a teardown of a genuinely stale-attr
worktree. It closes with a verdict the first time that runs.

Tracked to closure by
[#771](https://github.com/joshjhall/librarian/issues/771), so the open row is not
silently treated as closed by #768's merge.

Tally shape rather than a completed `-e2e-` report, deliberately: an `-e2e-` file
is a finished transcript, and this one opens now and fills later. (Named per
CLAUDE.md § `docs/verification/`.)

## Why CI cannot close this

The bug is a **filesystem** property, not a git or script property: on a macOS
Docker bind mount (virtiofs/bindfs) a committed symlink reports `nlink=0
size=0`, which defeats git's stat comparison so git marks the link `M` forever.
That cannot be reproduced on the ext4 filesystem CI runs on. Verified during
implementation:

- a committed symlink here reports `nlink=1 size=10` and stays clean
- `git update-index --cacheinfo`, a retarget-and-restore, and
  `core.checkStat minimal` all fail to manufacture it
- more sharply: on a sane filesystem an unstaged ` M ` symlink whose target
  matches the index is a **contradiction**, so the carve-out's positive arm has
  no natural fixture

`tests/golem-scripts/40-worktree-rm.sh` therefore drives the positive arm through
a `git` PATH stub replaying the `--raw` line **actually observed** on the live
`.worktrees/issue-760` worktree, while `cat-file`, `readlink` and every decision
branch run for real. The stub supplies the filesystem's lie and nothing else.

## What IS already proven (no live fixture needed)

| Behavior | Covered by |
| --- | --- |
| carve-out fires on a stale-attr symlink | `test_worktree_rm_forces_past_stale_symlink_attrs` |
| …and for a **non-ASCII** path | `test_worktree_rm_forces_past_stale_symlink_non_ascii_path` |
| count/disclosure correct at **N=2** | `test_worktree_rm_counts_multiple_stale_symlinks` |
| retargeted symlink still blocks | `test_worktree_rm_refuses_genuinely_retargeted_symlink` |
| dirty regular file still blocks | `test_worktree_rm_refuses_dirty_regular_file_beside_symlink` |
| deleted symlink still blocks | `test_worktree_rm_refuses_deleted_symlink` |
| file replaced by symlink blocks | `test_worktree_rm_refuses_file_replaced_by_symlink` |
| clean teardown makes no false claim | `test_worktree_rm_clean_teardown_has_no_symlink_disclosure` |

Mutation-verified: neutering the readlink comparison reddens the retarget test,
dropping the residue filter reddens the dirty-file test, and reverting
`core.quotePath=false` reddens the non-ASCII test. The `src_mode` gate survives
every mutation and is documented as unreachable defensive depth rather than
claimed as tested.

So the **negative** direction — real work still blocks — is fully covered. What
remains is confirming the positive arm against genuinely stale attributes rather
than a faithful replay of them.

## The live fixture

`.worktrees/issue-760` is deliberately **kept** — it is the worktree whose
blocked teardown motivated this issue, and it reproduces the condition:

```console
$ git -C .worktrees/issue-760 status --porcelain --ignore-submodules=all
 M .codegraph
 M AGENTS.md

$ git -C .worktrees/issue-760 diff --raw AGENTS.md .codegraph
:120000 120000 5223462 0000000 M	.codegraph
:120000 120000 681311e 0000000 M	AGENTS.md
```

`git cat-file -p 681311e` is `CLAUDE.md`, and `readlink AGENTS.md` is `CLAUDE.md`
— index blob and on-disk target match on both paths, so both are stat artifacts
and neither is real work.

## Procedure

From the **main checkout**, on merged `main`:

```bash
/workspace/librarian/plugins/workflow/scripts/worktree-rm.sh 760
```

Expected: exit 0; stdout contains `removed worktree .worktrees/issue-760 (forced
past 2 stale symlink attr(s))` — count **2**, for `AGENTS.md` and `.codegraph`;
the worktree directory is gone and the local branch deleted; no `has uncommitted
changes` refusal.

## Rows

| Date | Host / FS | Result |
| --- | --- | --- |
| _pending_ | macOS Docker / virtiofs | _not yet run_ |

## Verdict

_Open._ Closes when a row above records a real teardown. A failure here is a
genuine defect in the carve-out and reopens #768; a pass closes this file and
retires `.worktrees/issue-760`, which exists only as this fixture.
