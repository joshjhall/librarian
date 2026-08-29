---
name: harness-format-is-neither-module-nor-script
description: "A workflow.js can never import a sibling — and no bundler emits its format, because `export meta` + top-level `return` is contradictory ESM"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 491f9aa5-8fc9-439d-b0e2-f8489968d3a8
  modified: 2026-08-25T21:27:46.550Z
---

A `workflow.js` harness **cannot import anything**, and the reason is a parse-time
property of the format, not a policy. Probed live against the engine (#712):

| Attempt | Engine response |
| --- | --- |
| `import { X } from './dep.js'` mid-file | `SyntaxError: Unexpected token '{'. import call expects one or two arguments.` |
| `await import('./dep.js')` | `SyntaxError: import() is not available in workflow scripts.` |
| `import` hoisted above `meta` | `Invalid workflow script: export const meta … must be the FIRST statement` |

The first message is the informative one: the harness is parsed as a **script**,
not a module, so `import` is only ever read as the dynamic-call form — and that
form is disabled. There is no third spelling. This is the load-bearing reason
`BUDGET_FLOOR` is duplicated across all six harnesses instead of shared.

**So an oversized harness cannot be split in place.** Record a decline (the
`check-decomposition` scanner reaches the same verdict on its own axis:
`no low-coupling seam found — units are mutually referential`), and scope it —
impossible-to-split is not the same claim as fine-at-any-length.

## The trap when someone proposes a build step

The obvious fix is to keep editable fragments and generate the artifact. It
works, but **no off-the-shelf bundler emits this format**, because the format is
self-contradictory to standard module semantics — and the two constraints are
symmetric:

- `export const meta` forces ES-module semantics, under which the harness's own
  **top-level `return` is illegal** (`esbuild: Top-level return cannot be used
  inside an ECMAScript module`).
- Dropping the `export` to obtain a script makes **`import` illegal** again.

The shape that does work is **bundle-then-unwrap**: fragments and entry are
ordinary ES modules (the bundler owns resolution and ordering), the orchestration
body lives in an exported function, and a post-bundle step strips the `export`,
hoists that body to top level, and prepends the `meta` literal as a banner.
Verified end-to-end against the real engine.

Two things that decide whether it is worth it, both easy to miss:

- **A `@generated` banner does NOT silence the size row.** Measured: the
  `file-length` HIGH and `god-module` rows are unchanged; only the
  `decomposition-seam` wording shifts. So a generator is justified by **editing
  ergonomics** — agents degrade on long files — never by quieting the lens.
- **Plugin install copies the tree as-is and runs no build**, so the artifact
  must stay committed and generation can never be PR-tied. A missing optional
  gate skips loudly (exit 77); a **stale artifact silently runs old bytes**.
  The freshness gate is the load-bearing piece, not a nicety.

See [[two-runtime-model]] for what the sandbox otherwise forbids.
