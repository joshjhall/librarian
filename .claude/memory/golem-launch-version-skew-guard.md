---
name: golem-launch-version-skew-guard
description: "golem-launch.sh refuses dispatch on plugin version skew (running helper != active install); \"unknown\" registry sentinel must skip"
metadata: 
  node_type: memory
  type: project
  originSessionId: a2d41df7-e3ec-4bf3-90bc-cd59a3efca52
---

`golem-launch.sh` (workflow plugin) has a **version-skew guard** (#230, PR #237):
before dispatch it compares the running helper's plugin version (its sibling
`.claude-plugin/plugin.json`) against the active install
(`installed_plugins.json`, env-overridable via `CLAUDE_INSTALLED_PLUGINS`). On a
real mismatch `launch` refuses with exit 3 (before any tmux side effect);
`print` warns. Escape hatch `GOLEM_SKIP_VERSION_CHECK=1`.

**Why:** a stale cached orchestrate skill drags a stale `golem-launch.sh` via
`${CLAUDE_PLUGIN_ROOT}`; the old helper emitted bare `/next-issue`, which the
active plugin rejects as `Unknown command`, wedging every golem silently.

**How to apply:** the guard MUST fail safe — an undeterminable version skips
silently. Two non-obvious "undeterminable" cases (both bit an earlier draft):
(1) the registry stores `"version": "unknown"` as an in-band sentinel for
unversioned plugins (most of a real `installed_plugins.json`) — treat it as
empty, not a real value, or every dispatch false-refuses; (2) `$HOME` in a
`${VAR:-$HOME/...}` default aborts under `set -u` when HOME is unset — use
`${HOME:-}`. Both are covered by tests in `tests/validate-golem-scripts.sh`.
Note the acute symptom is already fixed upstream: the SKILL resolves the helper
from `${CLAUDE_PLUGIN_ROOT}` and the helper emits namespaced
`/workflow:next-issue`. Related: [[workflow-agenttype-namespacing]],
[[ship-issue-rename-rationale]].
