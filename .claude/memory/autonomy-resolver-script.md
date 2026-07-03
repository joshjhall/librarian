---
name: autonomy-resolver-script
description: "autonomy-resolve.{py,sh} is the single source of truth for the L1-L4 gate-disposition table; skills call it, don't re-derive"
metadata:
  node_type: memory
  type: project
  originSessionId: 9834ce3c-b52d-4d4e-b471-b37a6a4974c5
---

`plugins/workflow/scripts/autonomy-resolve.{py,sh}` (issue #190, on branch
feature/issue-190) is the deterministic resolver for the L1–L4 autonomy decision
table — level selection, the `severity/critical` cap, per-gate disposition, the
dead-end override, and the derived `autonomous`/`plan_gated` mirrors. Subcommands:
`level` (emits autonomy_level/autonomous/plan_gated/capped/perm_mode), `gate
<routine|escalation> --level N [--dead-end]` (emits disposition=auto|human),
`read` (legacy state-file level resolution). Python-3.11 primary + bash-3.2
fallback, `PATTERNS_FORCE_BASH=1` forces bash, byte-identical output pinned by
`tests/validate-autonomy-resolve.sh`.

**Why:** the table used to be prose copied across 7 skill markdown files and had
already drifted — orchestrate still gated the plan by *effort* while next-issue
had moved to *level*. Extracting to code kills that drift class.

**How to apply:** `/next-issue`, `/ship-issue`, `/orchestrate` all CALL the
resolver (`${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-resolve.sh …`) instead of
re-deriving the rules; the prose now *describes* it. The authoritative contract
is `orchestrate/autonomy-levels.md` (#174); when prose and resolver disagree, the
test's decision table is the tiebreak. Host-tool only — NOT reachable from
`workflow.js` (see [[two-runtime-model]]); level is computed in skill Bash steps.
Broad language reconciliation is separate (#181).
