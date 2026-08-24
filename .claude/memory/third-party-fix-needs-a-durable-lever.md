---
name: third-party-fix-needs-a-durable-lever
description: A patch to an installed plugin's files is clobbered by the next update — enumerate the config levers before editing bytes
metadata:
  type: feedback
---

When the fix for a defect lands in a **third-party plugin's installed files**,
patching those bytes is almost never the answer: `plugin update` overwrites them,
and the cost silently returns with no signal that it did. Enumerate the
**configuration** levers first, and prefer the one that survives updates.

Checked for `hookify` (#782/#793), in the order worth reusing:

| Lever | Durable? |
| --- | --- |
| Patch the plugin's files | **No** — clobbered by `plugin update` |
| Per-component (hooks-only) toggle | **Does not exist** — enable/disable is whole-plugin; `skillOverrides` covers skills, no `hookOverrides` counterpart |
| Global kill switch (`disableAllHooks`) | Durable but **too broad** — takes out your own correct hooks too |
| `enabledPlugins: false` | **Yes** — survives updates, one-line revert |

Two traps found by looking rather than assuming:

- **The installed copy is not the one you're reading.** `hookify` had *three*
  md5-identical copies — `cache/<version>`, `cache/<sha>`, and the
  `marketplaces/` checkout. A patch can land on a copy that never executes, which
  looks like the fix silently not working.
- **Check whether the plugin is doing any work at all.** No rule files existed
  anywhere, so its entire runtime contribution *was* the defect. That is what made
  disabling free — and it is a question worth asking before weighing a fix's
  cost, because it can collapse the decision entirely.

**Why:** the durable-lever question changes the recommendation, not just the
implementation. Reaching for the patch first produces a fix that decays silently.

**How to apply:** before editing any file under `~/.claude/plugins/`, ask what
survives `plugin update`. If nothing does, the fix is configuration plus an
upstream report — and say plainly that the local patch is temporary if you ship
one anyway. See [[verify-then-refetch-is-not-verified]] for the adjacent trap of
trusting a re-resolved artifact.
