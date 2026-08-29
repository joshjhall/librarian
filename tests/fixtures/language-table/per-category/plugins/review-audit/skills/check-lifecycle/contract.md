# check-lifecycle — Output Contract (fixture stub)

## Language Support

A MULTI-CATEGORY matrix, which is what makes this fixture different from every
other one here — the rest use a single synthetic column, so none of them can
express the per-cell defect (#847).

`.rs` is marked `M` in BOTH columns. It genuinely has an arm in
`unreaped-subprocess` (both runtimes) and NO arm in `unclosed-handle` (either
runtime). So the `unclosed-handle` cell is wrong.

Under the old row-collapsing check this tree passed: the row was OR-ed to a
single `M`, and the `unreaped-subprocess` arm satisfied it. That is exactly the
case the issue describes — "a wrong cell in one category column can pass as long
as some other column has an arm for the same extension".

<!-- contract: check-lifecycle-language-support -->

| Language | ext(s) | unreaped-subprocess | unclosed-handle |
| -------- | ------ | ------------------- | --------------- |
| Python   | py     | M                   | M               |
| Rust     | rs     | M                   | M               |

<!-- contract: end-check-lifecycle-language-support -->
