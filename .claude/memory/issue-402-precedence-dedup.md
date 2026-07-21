---
name: issue-402-precedence-dedup
description: "#402 SHIPPED PR #477 (L3, PARKED human-merge): agnix precedence dedup down-scope; adversarial review caught my real over-correction bug"
metadata: 
  node_type: memory
  type: project
  originSessionId: 1c804b9d-6cf9-446b-b4d3-5bb82f361bc0
  modified: 2026-07-21T15:32:37.558Z
---

# 402 (ADR-0001 item 4, "down-scope check-ai-config overlap to precedence-only

dedup, NOT deletion") SHIPPED as PR #477 on 2026-07-21 at L3. Parked for
human merge (auto-mode classifier blocked self-merge as usual — see
[[auto-mode-blocks-self-merge]]). CI fully green, review loop clean.

**What the change actually was:** #401 (PR #469) already landed the Step 6
precedence dedup in `checker.md`, but keyed it on exact `file:line`. The floor
(`patterns.py`/`patterns.sh`) anchors ALL `agent-frontmatter`/`skill-frontmatter`
findings at whole-file sentinel line `"1"`, while agnix reports `CC-AG-*`/`CC-SK-*`
at the real field line → exact-line key silently missed the frontmatter overlap →
duplicate survived on happy path (AC#1 violated). #402's residual delta was the
dedup KEY, not new wiring.

**The trap I fell into (and the adversarial pre-PR review caught):** my first
fix broadened the key to same-`file` + same-**category**. That over-corrected: the
floor emits MULTIPLE distinct findings per file+category (up to 4 frontmatter
fields all at line 1; hook-safety destructive+secret at different lines;
check_mcp_config several URLs). If agnix reports only ONE, a category-wide sweep
drops ALL check-ai-config findings in that category — deleting coverage agnix
never had, the exact silent hole #402 forbids, and contradicting my own "never
deletes coverage agnix lacks" prose. The Fable-judge review flagged this as HIGH
scope-drift (+ correctness/security siblings). **Correct fix = match PER
UNDERLYING ISSUE** (field/message correspondence, not line, not whole category):
drop only the specifically-superseded finding, retain every sibling agnix didn't
report. Because checker.md is LLM-followed prose, "same underlying issue" is a
judgment the checker agent can make.

**Reusable lessons:**

- When you broaden a dedup/match key to fix a false-negative, check you haven't
  created a false-positive at the coarser granularity — especially when one side
  emits N findings per key bucket. The safe key is the finest that still bridges
  the mismatch (here: per-issue, not per-line, not per-category).
- The adversarial pre-PR review earns its cost: it caught a real logic bug I'd
  have shipped. Fix at the ROOT — one per-issue rework killed 5 of 6 findings.
- Files touched: `checker.md` Step 6 + Step 3a fwd-ref, `validate-agnix-checker-wiring.sh`
  (per-issue assertions + no-whole-category-collapse + assert_not_contains
  regression guard), and ADR-0001 §2 one-line mechanism refresh. patterns.* NOT
  touched → TSV parity green trivially, scope guard honored.
- checker.md prose tokens the wiring test asserts must sit on ONE line — mdformat
  wraps at ~80 cols and `assert_contains` matches literal substrings, so a phrase
  split across a line break fails the gate. Reword to keep asserted tokens intact.

Related: [[issue-400-cross-repo-coordination]] (ADR-0001 spine),
[[check-ai-config-bloat-scan]], [[ship-review-diff-must-be-faithful]].
