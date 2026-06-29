---
description: Negative fixture for the subagent_type cross-reference gate (issue #41). This SKILL.md frontmatter names an agent that does not exist under plugins/*/agents/, so the cross-ref detector MUST flag it. Kept intentionally dangling — do not "fix" the reference.
subagent_type: this-agent-does-not-exist
---

# Dangling subagent_type fixture

Intentionally references a nonexistent agent so
`tests/validate-crossrefs.sh` can prove its dangling-reference detector fires.
