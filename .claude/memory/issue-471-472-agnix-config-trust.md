---
name: issue-471-472-agnix-config-trust
description: "#471/#472 shipped PR #547 — agnix never reads the audited repo's config; 3 review cycles each killed the prior design; --config ordering bug had made the trust branch dead since #398"
metadata: 
  node_type: memory
  type: project
  originSessionId: b472b132-b2dd-4c1e-b549-e5fb7417f5b6
  modified: 2026-07-28T19:18:07.775Z
  status: stable
  stale_after: 2026-10-31
  stale_check: "the 0.40.0/0.41.0 reproduction — re-verify the `--config` global-ordering behavior on the pinned version; the trust rule does not expire"
---

MERGED PR #547 (`a8b23c7`, human-directed merge 19:17Z) closing #471 + #472,
both `effort/trivial`, both agnix trust-surface follow-ups from #401/PR #469.

**Scope ended ~3x the labels.** Two trivial issues → 6 files, +290/−35, plus a
pre-existing normalizer bug and an ADR update. Driven by the pre-PR review, not
by drift: each of the 3 cycles found a sandbox-reproduced hole in the design the
previous cycle produced.

**The design turnover (all reproduced against pinned 0.40.0 AND 0.41.0):**

1. `git ls-files --error-unmatch` **cannot distinguish absent from untracked** —
   index-only, byte-identical exit 1 + stderr for both. Prose described a 3-way
   branch but named one command yielding a 2-way split.
2. **agnix config discovery walks up per-FILE, not from the repo root.** One
   nested untracked `.agnix.toml` suppressed `CC-AG-002` for EVERY scanned file.
   A repo-root check is the wrong scope entirely. (A config in a PARENT of the
   repo is NOT consulted — the walk is downward-rooted.)
3. **Tracked-ness cannot vouch for content.** A tracked entry may be a SYMLINK
   (index mode `120000`); a tracked regular file may use agnix's **`extend`** key
   to chain to an untracked sibling, an absolute path, or `../` traversal. Both
   are `ls-files`-clean; both silently suppress findings.

**Final design = remove the class, don't validate it.** Under
`CODEBASE_AUDIT_TRUST_PROJECT_SCRIPTS=1` the checker no longer reads the repo's
`.agnix.toml` at all — it always pins agnix to a checker-controlled default
config written outside the audited tree. Explicit `--config` suppresses the
upward walk (verified it also beats the `AGNIX_CONFIG` env var, `~/.agnix.toml`,
and XDG paths). 3 branches → 1; symlink/extend/TOCTOU/nested-plant all moot.
**Deliberate capability removal:** a repo's own committed config no longer
applies during audits.

**REUSABLE BUG — `--config` is a GLOBAL flag, must precede `validate`.** Both
normalizers emitted `... validate --config X`, which agnix rejects (`unexpected
argument '--config' found`, exit 2) on the PINNED 0.40.0 too — so the
`AGNIX_CONFIG` branch, the trust posture's *primary safe path*, had never worked
since #398. Invisible because both impls `2>/dev/null` agnix's stderr, so it
surfaced only as the generic "produced no JSON output" fail-loud.

**Why the existing test missed it:** `test_agnix_config_placement` asserted
`--config` preceded `--`, and its recording stub only began looking for
`--config` AFTER seeing `validate` — the stub was *built around the buggy order*,
so it structurally could not observe the correct one. Lesson: a stub that models
the current implementation can only ever confirm it.

**Prose-contract gotchas hit repeatedly this run:**

- `assert_contains` on a phrase that **wraps across a source line** silently
  fails — 4 separate occurrences. Anchor on the single-line half.
- A whole-region grep + `sort -u` **did NOT detect real drift** in the #472
  category-parity test: Step 6 names `hook-safety` 3x, so deleting the
  enumeration entry left the token present elsewhere. Scope the extraction to
  the enumeration sentence (`grep -A3 <anchor>`), then tamper-check drift from
  BOTH sides.
- `test -e` (not `-f`) is correct for the existence probe: a DIRECTORY named
  `.agnix.toml` is `-e` true / `-f` false, and `-f` would misroute it to the
  permissive branch.

**Bloat:** `checker.md` 631 → 676, further past its own `AGENT_HIGH=400`.
CI does NOT fail on this — nothing in `tests/` or the workflows gates on a real
repo file exceeding a bloat threshold (`validate-prescan-differential.sh` is a
bash↔python PARITY gate, not a finding-count gate). Tracked in [[issue-503-large-file-decompose]];
`STEP3A_MAX_LINES` (now 135) should come back DOWN when #503 extracts Step 3a.

Follow-ups filed: **#548** (pin the `unreadable` disjunct), **#549**
([[check-docs-staleness-ifs-colon-parity]] — now hit TWICE, #397 and this PR,
both times worked around by rewording).

Related: [[ship-review-diff-must-be-faithful]], [[auto-mode-blocks-self-merge]],
[[verify-squash-merge-landed]].
