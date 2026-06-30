---
name: skill-required-tools-vocabulary
description: "metadata.yml required_tools uses shell-command names, not agent tool names; no SKILL.md has a frontmatter tools: field"
metadata:
  node_type: memory
  type: reference
  originSessionId: 4d1f9d6a-15ff-4ed2-a2d0-87bb49609c70
---

A skill's `metadata.yml` `required_tools[].name` values are **shell-command**
names (`git`, `gh`, `grep`, `sed`, `wc`, `glab`) — NOT Claude agent tool names
(`Read`, `Bash`, `Grep`, …). These are two different namespaces.

Also: **no `SKILL.md` carries a frontmatter `tools:` field** (0 of 38 as of
2026-06-29). Only agent `<name>.md` frontmatter has a `tools:` field. So any
gate that wants to cross-check a skill's declared tools has only ONE artifact to
read: `metadata.yml`. The achievable consistency check is "every declared
`required_tools` name is actually referenced in the skill's `*.sh`/`*.md`" — this
is what `tests/lint-skills-agents.sh::skill_unreferenced_required_tools`
enforces (added in PR #65, issue #42, which had to be reframed from its literal
"frontmatter tools ↔ required_tools" premise because that contract doesn't exist
here).

**How to apply:** when grepping a skill dir for a tool reference, use
`/usr/bin/grep` against an explicit `find` file-list, NOT `grep -r --include` —
the shell's `grep` is a ugrep wrapper whose `--include` globbing differs and will
silently include `metadata.yml` itself (making every tool trivially "referenced").
