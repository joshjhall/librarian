# check-lifecycle — Output Contract (fixture stub)

## Language Support

Arms the comment-stripping rule in the `tag` binding.

`rs` is marked `—` for `unclosed-handle`, and that is correct: neither runtime
emits that category for `rs`. Both merely MENTION the tag in a comment inside the
`rs` arm.

A tag matcher that searches the raw arm body finds those mentions and concludes
`rs` is covered — so it reports the correct `—` cell as a MISMATCH. The failure
direction matters: a false claim of coverage silences a real finding elsewhere,
and here it manufactures one against a truthful matrix.

<!-- contract: check-lifecycle-language-support -->

| Language | ext(s) | unreaped-subprocess | unclosed-handle |
| -------- | ------ | ------------------- | --------------- |
| Python   | py     | M                   | M               |
| Rust     | rs     | M                   | —               |

<!-- contract: end-check-lifecycle-language-support -->
