---
name: dry-run-against-real-data
description: "A tool that mutates a corpus can be green on every fixture and silently destroy information on real input — run it against the real corpus and diff the downstream checker's output before/after"
type: feedback
metadata:
  node_type: memory
  originSessionId: fa608522-9973-4620-9bbb-8ebcd928aaf8
  modified: 2026-09-16T21:18:09.280Z
---

For a tool that **mutates a corpus** — a migration, a codemod, a bulk rewriter —
fixtures test the shapes someone thought to write. Real data contains the shapes
nobody did. Run the tool against a **copy of the real corpus**, run the real
downstream checker before and after, and diff the two reports.

The invariant is not "it ran" or "the diff looks right". It is: **the same
findings, and no new categories.** A migration must not change what the checker
sees. Every row true before is still true after; no row is invented.

Worked case (#934, `okf-migrate move-concept`). Suite was 80/80 green, six
adversarial review cycles had run, and a dry-run against this repo's own 262-file
memory bundle found two more defects in minutes — neither reachable from any
fixture, both silent, both in the PR's own new code:

- **80 known findings became 1, at exit 0.** The health pass walked only the
  bundle root, so a concept stopped being health-checked the moment the transform
  filed it into a directory. A migration that silences 79 real findings while
  reporting success reads as the migration having **fixed** them — which is
  exactly what a reviewer comparing before/after counts would have concluded.
- **The indexes themselves were moved.** One index merely *linking* to another
  made the target its "member", so `MEMORY.md` was relocated into a topic
  directory and every `index-*.md` into another. The checker then read each as a
  malformed concept.

**Why:** a fixture is a hypothesis about what can go wrong; real data is a sample
of what does. The failure this catches is specifically the one a green suite
cannot: *information silently disappearing*, where both the tool and its tests
report success because neither is looking at the quantity that shrank. Note the
direction of the first defect — fewer findings **looks like progress**. Any
metric that improves after a bulk rewrite deserves the same suspicion as one that
regresses ([[vacuous-scan-reads-as-a-clean-verdict]]).

**How to apply:** before shipping a corpus-mutating tool, copy the real corpus,
apply, and run the genuine downstream checker both sides. Assert row count and
category set, not just "no crash". Where the corpus is the repo's own, this is
cheap and needs no new infrastructure. Then keep the comparison as a **gate on
the real migration**, not merely as evidence — both defects above are invisible
in a diff review of a ~500-file change and obvious in that one comparison.

Related: [[parity-gate-hides-shared-defect]] (why cross-runtime agreement did not
catch these), [[whole-repo-diff-bounded-by-repo-content]] (the mirror-image trap:
a whole-repo check is bounded by what the repo happens to contain, so absent
shapes read as parity).
