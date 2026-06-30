---
description: Negative fixture for the subagent_type cross-reference gate (issue #85). This SKILL.md frontmatter names agents that do not exist under plugins/*/agents/ via the multi-value block list form, so the cross-ref detector MUST flag both. Kept intentionally dangling — do not "fix" the references.
subagent_type:
  - this-agent-does-not-exist
  - another-missing-agent
---

# Dangling subagent_type fixture (multi-value block list)

Intentionally references two nonexistent agents via the block list form so
`tests/validate-crossrefs.sh` can prove the collector extracts every name from a
multi-entry `subagent_type:` block list.
