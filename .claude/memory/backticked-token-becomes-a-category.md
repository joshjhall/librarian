---
name: backticked-token-becomes-a-category
description: A backticked lowercase-kebab word in a contract.md is scraped as a declared CATEGORY; language names and syntax keywords must stay unbackticked
metadata:
  type: feedback
---

`tests/validate-contracts.sh`'s `extract_contract_categories` greps **every**
`` `lowercase-kebab` `` token out of a whole `contract.md` and treats each as a
declared category, filtered only by a short fixed denylist (`version`,
`deterministic`, `heuristic`, `llm`, `finding-schema`, `compatible`). It is not
scoped to the `## Categories` section.

So prose like ``covers `js`/`jsx` but not `mjs` `` or ``no trailing `else` ``
silently injects `js`, `jsx`, `mjs`, `else` into the contract's category
namespace. A table of *language* names in backticks does the same.

**Why:** the cross-check at the call site is one-directional
(patterns→contract), so extras do **not** fail the gate today — the damage is
silent namespace pollution that surfaces later, as a mystery failure for whoever
tightens the assertion to bidirectional. `bin/check-patterns-coverage.sh` reads
the same files with a *different* scoping (`sed -n '/^## Categories/,/^## /p'`),
so the two consumers already disagree about what counts.

**How to apply:** in a `contract.md`, backtick only real category slugs. Write
language names, extensions and syntax keywords bare (.mjs, def, class, else).
After editing one, diff the extracted set against the pre-change baseline:

```bash
git show HEAD:<path> | grep -oE '`[a-z][a-z0-9-]+`' | tr -d '`' | sort -u
```

and confirm your version adds nothing. A new section placed **after**
`## Categories` also correctly terminates the coverage script's `sed` range —
placing it before would widen it.

Related: [[comment-asserts-intent-not-code]],
[[config-prose-satisfies-its-own-assertion]].
