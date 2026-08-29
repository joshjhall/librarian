# check-lifecycle — Output Contract (fixture stub)

## Language Support

Arms assertion 6 (`UNBOUND`). `future-detector` is a column the gate's BINDINGS
map does not know, and it carries an `M` cell — so that cell is unenforceable.

This is the shape of adding a modeled column and forgetting the binding. Without
assertion 6 the cell would simply be skipped: green, unchecked, and
indistinguishable from a cell that was verified. Note it is the `M` that makes it
a defect — an unbound column of `L`/`—` cells is the documented Phase 1 gap and
must stay silent, which is what the `unreaped-subprocess` column here holds
constant.

<!-- contract: check-lifecycle-language-support -->

| Language | ext(s) | unreaped-subprocess | future-detector |
| -------- | ------ | ------------------- | --------------- |
| Python   | py     | M                   | M               |

<!-- contract: end-check-lifecycle-language-support -->
