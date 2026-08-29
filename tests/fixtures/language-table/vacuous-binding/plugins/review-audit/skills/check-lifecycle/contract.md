# check-lifecycle — Output Contract (fixture stub)

## Language Support

Arms assertion 5 (`VACUOUS`) for the **Python** runtime. `vacuous-binding-sh/` is
the mirror image; see the note there on why the pair exists.

The matrix declares `unclosed-handle`, bound by category tag. The bash half emits
that tag; the Python half does not — so the binding resolves to an empty region
in one runtime only.

That is the stale-binding shape: rename a detector's emitted tag (or the function
an `fn` binding names) and the region silently stops matching. Every `—` cell in
that column then passes trivially and only `M` cells fail, which reads as a
scanner defect rather than as a broken gate. Assertion 5 exists to call it what
it is.

**Assertion 4 fires here too, and that is unavoidable rather than sloppy.** A
column vacuous in one runtime necessarily disagrees with whatever cells it has:
mark them `M` and the empty runtime has no arm; mark them `—` and the non-empty
runtime has one. There is no cell value that keeps assertion 4 quiet while the
region is asymmetrically empty, so this is the one fixture that legitimately arms
two assertions. The self-test asserts the VACUOUS line names the right runtime,
which is the part no other fixture covers.

<!-- contract: check-lifecycle-language-support -->

| Language | ext(s) | unreaped-subprocess | unclosed-handle |
| -------- | ------ | ------------------- | --------------- |
| Python   | py     | M                   | M               |

<!-- contract: end-check-lifecycle-language-support -->
