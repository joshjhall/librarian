---
name: deprecated-autonomy-flags-removed
description: "#215 hard-removed --autonomous/--auto/--plan-gate/--force-auto/NEXT_ISSUE_AUTONOMOUS; --level N is the sole autonomy dial"
metadata: 
  node_type: memory
  type: project
  originSessionId: df107511-9d75-4a82-a46f-f2d7aebc30e4
---

Issue #215 (PR #226, merged on `main` around 2026-07-04) hard-removed every
deprecated autonomy alias so **`--level {1,2,3,4}` is the sole autonomy input**.
No deprecation window — a clean break. Finished what #177/#179 started.

Removed for good (do NOT reintroduce): `--autonomous`, `--auto`, `--force-auto`,
`--skip-plan`, `--plan-gate`, `--no-skip-plan`, `NEXT_ISSUE_AUTONOMOUS` env,
the resolver's `--env-autonomous` + `--state-autonomous` inputs, the
`autonomous`/`plan_gated` **state-file mirror fields**, the ship-issue
legacy-boolean read path, and the Phase 0 `.md`→`.json` migration shim.

**Non-obvious distinction (easy to break):** `autonomy-resolve.{py,sh}`'s
`level` subcommand STILL emits 5 keys —
`autonomy_level / autonomous / plan_gated / capped / perm_mode`. Only the
*state-file persistence* of `autonomous`/`plan_gated` was dropped; `plan_gated`
and `perm_mode` remain **runtime dispositions** the skills consume in-session to
branch the plan gate and permission mode. So a future edit must not strip those
keys from resolver output — persist only `autonomy_level`.

"L4 but keep the plan gate" is now expressed as **L3** (the documented
`--plan-gate` replacement) — a genuine small capability loss, flagged
BREAKING CHANGE in the commit footer.

Excluded/untouched (never conflate — see [[autonomy-vs-plangate-flags]]):
`--force-target`/`--no-deps`, and the unrelated `--auto*` spellings
(`gh pr merge --auto`, `bin/release.sh --auto-*`, `/codebase-audit --auto-fix`,
`--permission-mode auto`). Resolver is the single source of truth —
[[autonomy-resolver-script]].
