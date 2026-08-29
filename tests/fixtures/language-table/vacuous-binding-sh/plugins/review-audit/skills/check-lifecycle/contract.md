# check-lifecycle — Output Contract (fixture stub)

## Language Support

MIRROR of `vacuous-binding/`: arms assertion 5 (`VACUOUS`) for the **bash**
runtime. That tree does the same for Python; see its note on why the pair exists
rather than one symmetric fixture.

The matrix declares `unclosed-handle`, bound by category tag. The Python half
emits that tag; the bash half does not — so the binding resolves to an empty
region in the bash runtime only.

Assertion 4 fires here as well, for the reason spelled out in the sibling
fixture: a column vacuous in one runtime necessarily disagrees with whatever
cells it carries, whichever value they take. What this tree uniquely pins is that
the VACUOUS line names `patterns.sh` — its sibling proves the same for
`patterns.py`, and neither branch is provable without the other.

<!-- contract: check-lifecycle-language-support -->

| Language | ext(s) | unreaped-subprocess | unclosed-handle |
| -------- | ------ | ------------------- | --------------- |
| Python   | py     | M                   | M               |

<!-- contract: end-check-lifecycle-language-support -->
