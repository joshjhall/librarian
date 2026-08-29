# check-code-health — Output Contract (fixture stub)

## Language Support

Arms the **`fn`** binding kind. `debug-print` and `debugger` both emit the single
`debug-statement` category, so a tag binding cannot tell them apart — they are
bound by the enclosing function name in each runtime instead.

The two columns have DIFFERENT coverage, which is the whole reason the `fn` kind
exists: `rs` is covered by the debugger family only. A regression in the
function-scope tracking (`py_arms`/`sh_arms`) collapses the two regions together
and `rs` starts looking covered by `debug-print` too, contradicting its `—` cell.

<!-- contract: check-code-health-language-support -->

| Language | ext(s) | debug-print | debugger |
| -------- | ------ | ----------- | -------- |
| Python   | py     | M           | M        |
| Rust     | rs     | —           | M        |

<!-- contract: end-check-code-health-language-support -->
