---
description: NEGATIVE FIXTURE skill — proves the required_tools reference detector fires. Not a real skill; do not install.
---

# skill-tooldrift-bad (negative fixture)

This is a deliberately broken fixture for `tests/lint-skills-agents.sh`. Its
`metadata.yml` declares two `required_tools`:

- `grep` — referenced right here in this sentence, so it must NOT be flagged.
- A second tool that is declared in `metadata.yml` but is deliberately NOT named
  anywhere in this dir's `*.sh`/`*.md`, so the
  `skill_unreferenced_required_tools` detector MUST flag it as drift.

DO NOT name that second tool anywhere in this file — it must stay unreferenced
so the guard has something to catch.
