# check-lifecycle — Output Contract (fixture stub)

## Language Support

Arms the SAME-LINE `;;` case (#847). `.rs` is correctly marked `—`: the bash half
has no `rs` arm of its own. It only appears to have one if the arm splitter runs
past a skip-list arm whose `;;` sits on the pattern line itself.

<!-- contract: check-lifecycle-language-support -->

| Language | ext(s) | unreaped-subprocess |
| -------- | ------ | ------------------- |
| Python   | py     | M                   |
| Rust     | rs     | —                   |

<!-- contract: end-check-lifecycle-language-support -->
