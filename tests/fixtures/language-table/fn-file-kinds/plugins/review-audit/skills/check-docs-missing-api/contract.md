# check-docs-missing-api — Output Contract (fixture stub)

## Language Support

Arms the **`file`** binding kind, and two parsing behaviors that had no fixture.

`file` kind: this scanner has ONE modeled column and its Python half emits no
literal category tag, so the binding is the whole-file union — which is only
correct because there is a single modeled column to attribute everything to.

Two parser cases ride along here because this is the shape that exercises them:

1. **Escaped pipes.** The "public-symbol form" column contains `\|` alternations,
   copying the real contract.md. A splitter that splits on a bare `|` shatters
   this row into extra columns and shifts every later cell left — so the parser
   reads a prose fragment where the `M`/`—` state should be. Harmless while rows
   were OR-ed together; load-bearing once cells must align.

2. **A narrowing parenthetical.** The Rust row's cell is `M (rs only)`. Since
   #847 that qualifier is enforced rather than prose, so it must restrict the
   cell to the extensions it names.

<!-- contract: check-docs-missing-api-language-support -->

| Language   | ext(s)  | public-symbol form        | undocumented-public-api |
| ---------- | ------- | ------------------------- | ----------------------- |
| Python     | py      | `def\|class`              | M                       |
| Rust       | rs, rlib | `pub fn\|struct\|enum`    | M (rs only)             |

<!-- contract: end-check-docs-missing-api-language-support -->
