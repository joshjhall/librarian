# bindfs ghost `index.lock` in the main checkout — evidence for #1193

**Verdict:** the stale, byte-identical `.git/index.lock` files are produced by
the **devcontainer's filesystem stack**, not by any librarian process. A single
writer running git's lock protocol on that mount, with no other process
involved, reproduces every symptom. The same writer on the container's overlay
`/tmp` never does. The fix belongs to joshjhall/containers (cross-filed; link in
the #1193 thread). Librarian ships a read-only detector so the symptom is named
early instead of failing a later `git pull`.

Measured 2026-10-07, in the session that worked #1193.

## The mount stack

`/workspace/librarian` (the main checkout, and every `.worktrees/issue-N` under
it) is two stacked mounts:

```text
476 461 0:49 /DX/librarian /workspace/librarian rw,... - virtiofs none rw,negative_dentry_timeout=3481699456
420 476 0:65 / /workspace/librarian rw,... - fuse /workspace/librarian rw,user_id=0,group_id=0,default_permissions,allow_other
```

The FUSE layer is `bindfs 1.14.7`, started by the containers image
(`containers/lib/runtime/lib/setup-bindfs.sh`, enabled in
`.devcontainer/docker-compose.yml`) to remap macOS/VirtioFS ownership:

```text
bindfs --force-user=vscode --force-group=vscode --create-for-user=1000 \
  --create-for-group=1000 --perms=u+rwX,gd+rX,od+rX -o allow_other \
  /workspace/librarian /workspace/librarian
```

Host: `Linux 7.0.14-linuxkit aarch64` (Docker Desktop on macOS). Every process
in the container, including the Zed remote server, the codegraph and filesystem
MCP servers, and every golem, resolves the path through the bindfs layer (same
`st_dev`).

## The reproduction

`bin/probe-fuse-rename.sh <dir> [cycles]` replays what git does on every index
write — exclusive-create `index.lock`, write it, rename it over `index` — in a
scratch subdirectory, with **one** process and no concurrent reader. After each
cycle it checks three guarantees a correct filesystem makes.

| Run location                 | Cycles | Anomaly rows | Fault episodes |
| ---------------------------- | -----: | -----------: | -------------: |
| bindfs mount (this worktree) | 20,000 |           16 |        9 (+1) |
| overlay `/tmp` (control)     | 12,000 |            0 |              0 |

**Count episodes, not rows.** A `rename-lost-source` row is usually followed
on the next cycle by an `exclusive-create-refused` row, because the
filesystem still reports the lost entry. The final probe removes the lock in
every anomaly branch (a review finding: the first version did not, which could
manufacture that second row itself). The pairing **persists after that
cleanup**: `rm -f` finds nothing to remove, but an exclusive create still
reports the file as existing, so each pair is one fault seen twice. Of the 9
episodes, 7 were such pairs and 2 were single rows. The "+1" is a third symptom
that version of the probe did not yet count: a write to a lock that the same
cycle had just created exclusively failed with ENOENT. It is now reported as
`write-lost-file`.

The rate is bursty: several 2,000-cycle runs were clean. Earlier, superseded
figures (10 rows in 16,000, from the probe before the cleanup fix) were quoted
in the #1193 thread and in joshjhall/containers#1086. Those rows are
over-counted relative to episodes; the conclusion does not change, since the
control stays at 0.

Observed anomaly kinds (raw rows, `inode size mtime`):

```text
# A rename succeeded, yet index.lock is still visible — then the next
# exclusive create is refused. This is the `git pull` failure verbatim.
VISIBLE-after-rename iter 1375: 17527995 150000 22:20:53.055001080 | 17527996 150000 22:20:53.060559500
EEXIST iter 1376:              17527995 150000 22:20:53.055001080 | 17527996 150000 22:20:53.060559500

# The rename could not find the lock it had just been handed.
anomaly=rename-lost-source cycle=1874 index=[17568342 150000 22:25:35.342920897] lock=[absent]
anomaly=exclusive-create-refused cycle=1875 ...

# Once, a 0-byte phantom lock.
EEXIST iter 1641: 17531676 150000 22:21:06.776100330 | 17531679 0 22:21:06.778180190
```

Two concurrency probes found **nothing**:

- 3 concurrent stat/cat/ls readers against the rename loop: 0 in 4,000.
- 4 concurrent `git status` writers on one scratch repo (1,600 runs total):
  0 failures, 21 in-flight lock sightings, all ordinary.

So the trigger is not git-on-git contention. It is the mount's
directory-entry/attribute caching around `rename(2)`, which a lone writer hits.

## How this explains the issue's clue

The issue's strongest clue was a stale lock that was byte-identical to `index`
with the same nanosecond mtime. In the probe, the post-rename ghost entry
appears in the same window that consumed the lock. A cached `index.lock` entry
that still resolves to the inode now named `index` would show exactly that
signature, with no hard link and no `cp -p` anywhere. Not proven at the inode
level: the main-checkout incidents were removed before anyone ran `stat -c %i`.
The probe's ghost rows show distinct inode numbers, so the probe proves the
class (a lock visible after rename), not the identical-inode form.

## Ruled out

- **Librarian code writing main's index.** Grepped `plugins/ bin/ tests/` for
  `cp -p`, rsync, hard links, and `GIT_INDEX_FILE`: none targets the main
  checkout. The watchers (`golem-gate-watch.sh`, `golem-mode-check.sh`) only
  run `git -C <worktree>`. Golem pushes use their worktree git dir (already in
  the issue).
- **Concurrent git processes** (see above).

## Not proven / open

- **Which layer.** The raw virtiofs layer is not reachable without root
  (`sudo` needs a password; `/proc/<bindfs pid>/cwd` is denied), so bindfs
  versus virtiofs could not be separated. The candidates for the containers fix
  to try are FUSE cache options on the bindfs mount
  (`-o entry_timeout=0,attr_timeout=0`, untested here) or keeping `.git` off
  the overlay.
- **The 15:38 emptied index** (65 bytes, every file a staged deletion). It was
  not reproduced. The 0-byte phantom lock is suggestive: git reading a cached
  short or empty view during a refresh would rewrite an empty index. This is
  unproven, and recorded as such.
- **Live main-checkout capture.** Main was observed read-only by operator
  directive (no `git status` there), and no stale lock occurred during this
  session.

## Mitigation shipped here

`plugins/workflow/scripts/main-index-lock-check.sh` (tested by
`tests/validate-main-index-lock-check.sh`). It runs no git, never deletes, and
reports `stale identical=yes` for the ghost signature. `orchestrate`'s
monitor protocol runs it before a main-checkout git write.
