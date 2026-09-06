# Wedged-worktree quarantine — issue #936

Records the live evidence for
[#936](https://github.com/joshjhall/librarian/issues/936)
("quarantine a wedged worktree so the `issue-N` path is always freed"), items
**1** (the quarantine fallback) and **3** (the root-cause correction).

This file exists because the triggering condition **cannot be reproduced
in-session**: the `EBADF`-on-`readdir`-visible-entries state comes from a host
virtiofsd that has lost its inode mapping, and every development host in this
project runs Linux/overlayfs (probed: both `/workspace` and `/cache` report
`overlayfs`). The measurements below therefore split in two — what was measured
**directly here** (the mechanics the fix depends on), and what came from the
**live remnants** reported in the issue (the condition itself).

## Why a quarantine, rather than removing harder

Issue #834 taught `remove_leftover_dir` to **tolerate** entries the filesystem refuses
to unlink. That was correct — nothing git-tracked is at risk — but it left the
`issue-N` **path occupied**, and the path is what callers actually need.

Measured here, on the ordinary filesystem, because it needs no virtiofs:

```console
$ git worktree add .worktrees/issue-5 -b feature/issue-5
fatal: '.worktrees/issue-5' already exists
```

So an occupied path makes the issue permanently un-workable on that machine
until someone clears it by hand. Removing harder is not an option: the entries
cannot be unlinked at all, which is the premise.

## The asymmetry the fix rests on

The wedged **entries** cannot be unlinked, but the **containing directory**
renames fine. Reproduced locally with a stand-in for the wedge (a child whose
parent directory is unwritable — `rm` cannot unlink it, and carries on with its
siblings, which is the shape the fix depends on):

| operation | result |
| --- | --- |
| `rm -rf` the tree | fails; entries survive |
| `mv` the tree aside | **succeeds**, contents intact |
| re-create the freed path | succeeds |
| `git worktree add` at the freed path | **succeeds** |

The issue reports the same asymmetry against the two genuinely-wedged remnants
(`mv issue-849 .wedged-issue-849-…` succeeded, after which `issue-849` could be
recreated, written to and `rm -rf`'d normally).

## The nesting hazard, reproduced

The distinct `-<epoch>-<pid>` suffix is not cosmetic. With a **bare**
destination name, quarantining twice does not produce two siblings:

```console
$ mkdir a && mv a .wedged-a
$ mkdir a && mv a .wedged-a
$ find .
./.wedged-a
./.wedged-a/a        <-- the second tree is INSIDE the first
```

`mv` onto an **existing** directory moves the source into it. That buries one
wedged tree inside another, where an operator's `ls` will not show it. The same
reasoning rules out `mktemp -d` for the destination: it *creates* the directory,
which is precisely the state that causes the nesting.

`tests/golem-scripts/40-worktree-rm.sh` pins this
(`test_worktree_rm_two_quarantines_are_siblings_not_nested`), and the mutation
round below confirms the assertion has teeth.

## The rename is not assumed

It can itself fail:

```console
$ chmod 500 wtdir            # unwritable parent
$ mv wtdir/issue-1 wtdir/.wedged-x
mv: cannot move … : Permission denied      (rc=1)
```

So the code branches on the rename's actual result and falls back to the
in-place reporting that preceded this change, rather than announcing a
quarantine that did not happen.

## End-to-end, against a wedged fixture

```text
worktree-rm: .worktrees/issue-77 is no longer registered as a worktree
  (nothing git-tracked left to lose) — removing the leftover directory
  cleared leftover directory .worktrees/issue-77 (5 entries could not be removed)
  the path was still occupied, so it was moved aside to .worktrees/.wedged-issue-77-1788723308-365431
  .worktrees/issue-77 is free again (no disk space is reclaimed in-container —
   those entries are names with no reachable inode; only a host
   unlink or a Docker VM restart releases the space)
  (expected on the macOS virtiofs mount stack — nothing git-tracked is at risk)
Deleted branch feature/issue-77 (was 0548c12).
  deleted branch feature/issue-77
```

Note what the tail of that output shows: teardown **continues** to the branch
step. Freeing the path did not turn an expected platform condition into a
failure — the #834 property, preserved.

A second teardown at the same path produced a **sibling**, not a nested tree:

```text
.wedged-issue-77-1788723308-365431
.wedged-issue-77-1788723322-395479
```

## What is NOT reclaimed

Summing live file sizes across both live remnants gives **0 bytes** — every
wedged entry is a name with no reachable inode. The multi-GB figure operators
see is host-side space that only a host unlink or a Docker VM restart releases.
A quarantine frees a **path**, not disk, and the message says so explicitly;
`test_worktree_rm_quarantine_does_not_claim_reclaimed_space` pins that it keeps
saying so.

## Root cause: virtiofs, not bindfs (item 3)

`remove_leftover_dir`'s comment attributed the `EBADF` to "the documented
macOS/VirtioFS `bindfs` overlay", pointing a future reader at the wrong layer.
The issue's measurements, recorded here so nobody re-runs them:

- Unmounting the bindfs overlay in a private mount namespace
  (`unshare -m --propagation private` + `umount -l`) leaves the entries failing
  **identically** on the bare virtiofs beneath.
- A freshly established `mount -t virtiofs host /mnt/fresh` in that namespace
  fails the same way — so it is not a container-side dentry cache either
  (`drop_caches` unavailable, `/proc/sys` read-only).

The host virtiofsd has lost the inode mapping. **No in-container call repairs
it**, so no amount of bindfs reconfiguration will fix it. The comment now says
this, and `test_worktree_rm_attributes_ebadf_to_virtiofs` pins it against the
source — the wrong attribution costs a reader a refactor of a layer with nothing
to fix, and nothing in the runtime output would ever reveal the error.

## Mutation round

Each rule was neutered against a snapshot copy (never `git checkout` — the fix
was uncommitted at the time), with the edit **asserted present on disk** before
the verdict was trusted, since an un-applied mutation runs pristine code and
reads as a survivor.

That guard earned itself twice, in opposite directions. A false **negative**:
the first attempt failed with `grep: invalid option -- '$'` because the anchor
began with `-`, and correctly reported `anchor not found` rather than a silent
"survived". Then a false **positive**: the `unconditional` mutation *appends* to
its anchor (`… ]; then` → `… ] && false; then`), so the anchor text survives as
a prefix of its own replacement and re-grepping it reported "still present" on a
mutation that had applied correctly (confirmed by reading the file). The check
is now a `cmp` against the pristine copy, which cannot be fooled either way.

| mutation | caught by |
| --- | --- |
| drop the `-<epoch>-<pid>` suffix (bare destination) | **6** tests, incl. siblings-not-nested |
| disable the rename entirely | **7** tests, incl. the disk-space message |
| `rm -rf` instead of the rename | **8** tests, incl. the idempotent re-run |
| quarantine to an empty dir (rename succeeds, contents lost) | **5** tests, incl. contents-survive |
| quarantine unconditionally | **3** tests, incl. the narrowness case |
| revert the attribution to bindfs | **1** test (the source-reading case) |

**No survivors.** Every rule the change introduces is detected by at least one
test, and each of the six was confirmed applied on disk before its verdict was
read.

One note on the third and fourth rows, because the distinction is easy to miss.
A plain `rm -rf` mutation does **not** isolate the contents-survive AC on this
fixture: the fixture blocks `rm` by construction (that is what makes it a wedge
stand-in), so the mutant falls to the failure branch and is caught by the
*path-freed* tests instead. To exercise the contents assertion specifically, the
fourth mutation replaces the rename with a `mkdir` of the destination — the path
is freed and the `.wedged-*` sibling exists, so only an assertion about the
tree's **contents** can tell the difference.

## Deferred

Item **2** (`worktree-new.sh` setting a per-worktree `CARGO_TARGET_DIR`) is
split into its own issue by operator decision, as #936's own note anticipated.
The measurement that motivated the split, recorded so it is not re-derived: git
**ignores** a per-worktree `.git/worktrees/<wt>/info/exclude` (only the shared
`.git/info/exclude` is honored), so a `.cargo/config.toml` written into a
worktree reads **dirty** — and `worktree-rm.sh` refuses teardown on a dirty
worktree. The naive mechanism would trade a rare wedge for a guaranteed teardown
refusal on every golem.
