---
description: Context for data storage work — databases, SQL, ORM, migrations, query optimization, and connection management. Activate when building data access layers, writing migrations, or optimizing queries.
---

# context-data-storage

Activates data storage-focused skills across pipeline phases when the work
involves databases, SQL, ORM, migrations, or query performance.

**Machine-readable mapping**: See `context.yml` for the phase-to-skill
mapping consumed by the pipeline orchestrator.

## When to Activate

- Building or modifying database access layers
- Writing SQL queries or ORM operations
- Creating or modifying database migrations
- Optimizing query performance or adding indexes
- Configuring connection pools or database connections

## What This Context Adds

| Phase         | Effect                                                        |
| ------------- | ------------------------------------------------------------- |
| **Plan**      | Data modeling and connection management requirements surfaced |
| **Implement** | `loop-make-it-secure` activated with SQL injection focus      |
| **Review**    | Query performance and injection check-\* skills run           |
| **Test**      | Connection failure, timeout, and constraint tests prioritized |
| **Docs**      | Schema decisions and migration steps documented               |

## Project-Level Override

Place a modified `context.yml` in `.claude/skills/context-data-storage/` to
customize the phase mapping for your project's data storage requirements.
