---
name: sync-script-clobbers-nested-region
description: A region-copy script that replaces a shared block wholesale silently deletes any INNER shared region nested inside it
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9a981892-012f-47f0-9278-e9cab649b220
  modified: 2026-08-23T00:59:46.837Z
---

When propagating a `# >>> shared:<name>` region from a source-of-truth file into
its pinned copies, a script that replaces the region **body wholesale** silently
deletes any **inner** shared region nested inside it — sentinels and all.

Concretely (#727): `shared:unit-segmenters-awk` sits *inside*
`shared:loc-helpers-awk` in `sizing.sh`. Copying `loc-helpers-awk` from
`patterns.sh` — which at the time had no inner sentinels — wiped the inner
region, and the sync gate then failed with "one opening sentinel … Expected '1',
Actual '0'" rather than a drift diff.

**Why:** the outer region's body is not a leaf. Nesting is invisible to a
line-range replace, and the text you paste is authoritative for everything
between the outer sentinels — including structure the destination had and the
source did not.

**How to apply:** before running a region-copy script, `grep -n 'shared:'` the
DESTINATION and check whether any region's bounds fall *inside* the one being
replaced. If so, either add the inner sentinels to the source so it carries the
nesting too, or copy the inner region separately afterward. Then re-run the sync
gate — the sentinel-count assertion catches this, and it reads as a structural
error, not as drift.

Two corollaries, both hit in the same issue:

- **Sync AFTER resolving, never before.** Running the copy while the source
  still held a conflict marker propagated the marker into every copy.
- **A region held by three files needs all three registered.** `patterns.sh`
  carried `unit-segmenters-awk` with no inner sentinels, so it was pinned only
  *transitively* through `sizing.sh` — and two of three copies can drift while
  the gate stays green. See [[parity-gate-hides-shared-defect]].
