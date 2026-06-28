---
description: Resolve import ordering merge conflicts by combining, deduplicating, and sorting. Use when both sides of a merge added imports to the same block.
---

# Rebase Imports

Resolves import ordering conflicts by combining both sets of imports,
deduplicating, and sorting according to language conventions.

## Detection

Import conflicts look like:

```text
<<<<<<< HEAD
import { foo } from './foo';
import { bar } from './bar';
=======
import { foo } from './foo';
import { baz } from './baz';
>>>>>>> agent01
```

Both sides added imports — the resolution is to keep all of them.

## Resolution by Language

### JavaScript / TypeScript

1. Collect all imports from both sides
1. Deduplicate by module path
1. Sort groups: node builtins, external packages (`@`-scoped first), local (`./`, `../`)
1. Within each group, sort alphabetically by path

### Python

1. Collect all imports from both sides
1. Deduplicate by module name
1. Sort groups (isort convention): `__future__`, stdlib, third-party, local
1. Within each group, sort alphabetically

### Go

1. Collect all imports from both sides
1. Deduplicate by package path
1. Sort groups: stdlib, external (contains `.`)
1. Within each group, sort alphabetically

### Java / Kotlin

1. Collect all imports from both sides
1. Deduplicate by fully-qualified class name
1. Sort by package hierarchy alphabetically
1. Group: `java.*`, `javax.*`, external, project-local

### Other Languages

For languages not listed above: combine, deduplicate, and sort alphabetically.

## Resolution Steps

1. **Read the conflicted file** and find the import block with conflict markers
1. **Extract imports** from both sides (between `<<<<<<<` and `>>>>>>>`)
1. **Combine and deduplicate** — keep all unique imports
1. **Sort** according to language conventions above
1. **Replace** the entire conflict block with the sorted imports
1. **Stage** the resolved file: `git add <file>`

## When NOT to Use

- Conflicts outside import blocks (even if they involve `import` statements
  in function bodies)
- When imports have been intentionally reordered for a reason (rare)
- When the conflict involves removing imports (one side removed, other added)
