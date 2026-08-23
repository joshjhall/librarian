# worktree-rm.sh stale-symlink carve-out — live-fixture tally (#768)

**Status: CLOSED — PASS.** The automated proof shipped with #768; this file held
the one check CI structurally cannot run, a teardown of a genuinely stale-attr
worktree. That ran on 2026-08-23 and passed — see § Verdict, which also records
two corrections to the assumptions below.

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
| 2026-08-23 | Linux devcontainer / bind mount | **PASS** — `removed worktree .worktrees/issue-60 (forced past 2 stale symlink attr(s))` |
| 2026-08-23 | Linux devcontainer / bind mount | n/a — `.worktrees/issue-760` had **self-healed** before it could be tested (see below) |

## Verdict

**CLOSED — PASS.** The carve-out fired on a genuinely stale worktree and printed
the expected disclosure, on a real artifact rather than a replay:

```console
$ plugins/workflow/scripts/worktree-rm.sh 60
  removed worktree .worktrees/issue-60 (forced past 2 stale symlink attr(s))
Deleted branch feature/issue-60 (was ba3cb43).
  deleted branch feature/issue-60
```

Two corrections to this file's own earlier assumptions, both worth recording
because they change what the next reader should expect.

**1. The artifact is TRANSIENT, not permanent.** `.worktrees/issue-760` was kept
specifically as the fixture, and by the time the fix landed it had **self-healed**
— `stat` reported `nlink=1 size=9` and `status --porcelain` was empty, so it tore
down via the ordinary path and never exercised the carve-out at all. The issue's
framing ("`ln -sfn` clears it for minutes at most") is right that the state
churns, but the corollary was missed: a kept fixture can heal while you wait for
it. The run that actually proved the fix used a **different** worktree
(`.worktrees/issue-60`, incidental debris from a debugging session) that happened
to be stale at that moment.

The practical consequence: **do not plan a verification around one preserved
worktree.** Any worktree carrying committed symlinks on an affected mount is a
candidate, and whichever is stale *right now* is the one to use.

**2. It is not macOS/virtiofs-only.** Both rows above are a Linux devcontainer on
a bind mount. The issue attributed the artifact to "macOS Docker (virtiofs)";
that is where it was first seen, not its full range.

Neither correction affects the fix — the discriminator is the same, and the
negative arms (real work still blocks) were always covered by the suite. What
changed is the verification story: the live proof arrived opportunistically
rather than from the preserved fixture, and the fixture itself is now retired.

Follow-up [#771](https://github.com/joshjhall/librarian/issues/771) can be closed
by this result.
