---
name: extracted-region-breaks-its-slicers
description: Moving code out of a file breaks every test that sed-slices a region from it — the slice yields empty, the eval is a no-op, and the assertions fail as if the SUBJECT regressed
metadata:
  type: feedback
---

A test that drives a function by slicing it out of its source
(`eval "$(sed -n "/^name() {/,/^}/p" "$file")"`) has an invisible dependency on
that code's ADDRESS, not just its behaviour. Move the region to another file and
the slice matches nothing: the `eval` is a silent no-op, the driver runs with the
function undefined, and the assertions fail — reporting the *subject* as broken
when the extraction is what moved.

**Why:** the failure names the wrong thing. Splitting a file is usually
accompanied by real behavioural risk, so a red gate right after one reads as
"the split broke the code", and the natural next move is to go looking in the
subject. The actual defect is a path in the test. Worse, an anchor that still
matches something after the move is the dangerous case — it silently drives a
*different* region.

**How to apply:** before splitting or moving code, grep the test tree for
extractors keyed on it — `sed -n "/^<name>/`, `awk '/^<name>/`, `grep -A` with a
function name — and treat each hit as a consumer of the layout you are changing.
Then decide per anchor: keep the region where it is (record the constraint in a
comment beside it, and note which files depend on it), or teach the slicer to
LOCATE its region (`grep -rl '^<anchor>' <dir> | head -n1`) rather than assume
the file. Prefer locating: it survives the next move too. Verify by running those
gates specifically — a green unrelated suite proves nothing, because a slicer
that extracts nothing still exits 0 until its assertions run.

Measured on #960: moving `run-all.sh`'s stage dispatches into shard fragments
broke `validate-skip-visibility.sh`, which sliced the node if/else block from
that file. Four gates slice from `run-all.sh`; the other three took only
function definitions, which deliberately stayed at column 0 — so the constraint
was known and still cost a debugging cycle for the one region that moved.

Related: [[render-diff-before-and-after-an-extraction]],
[[split-verify-proves-the-split]], [[split-entry-point-drops-the-reporter]],
[[the-correct-copy-is-the-one-under-test]]
