---
name: token-scrape-transcript-dedup
description: golem-status token counter scrapes the Claude Code transcript; MUST dedup by message.id or it triple-counts
metadata: 
  node_type: memory
  type: project
  originSessionId: 6d93bf87-8599-414e-a1f4-97789af5f61a
  modified: 2026-07-18T19:30:02.727Z
---

Issue #371 (PR #393) instrumented #369's "frozen top-level token counter" takeover
signal: `golem-token-scrape.sh` sums a golem's TOP-LEVEL `output_tokens` from its
Claude Code session transcript (`$HOME/.claude/projects/<slug>/<session>.jsonl`,
slug = worktree abs-path with `/` and `.` → `-`), and `golem-status.sh` renders a
`TOP-LEVEL TOKENS` section (`frozen Xm`/`advancing`/`first reading`/`tokens
unknown`) + persists `top_level_tokens`/`top_level_tokens_at` to the cache.

**The load-bearing gotcha (pre-PR review caught it, HIGH):** Claude Code writes
**one transcript line per assistant CONTENT BLOCK** (thinking / text / each
tool_use), NOT one per turn — and every line of a turn repeats that turn's SAME
`usage.output_tokens`. A naive per-line sum inflates ~2.7x (verified: 711480 naive
vs 252931 deduped on one real transcript). **Fix = dedup by `message.id`**
(`group_by` id, take one value per id). Filter `isSidechain==false` for top-level
(exactly the top-level-vs-sub-workflow split the contract needs; a bare pane
counter can't express it). `output_tokens` only — cache-read/creation balloon and
aren't "work".

**Scope:** Mode 2 worktree golems only (transcript host-readable). Mode 3
container transcripts are in-container → row shows `n/a (… see #390)`; host-side
HTTP-POST propagation = follow-up #390. Deferred coverage/README = #392.

**Frozen-since bookkeeping:** carry `top_level_tokens_at` forward byte-identically
while the count is unchanged, reset to now() only when it moves. A substring test
(`"150 tokens, frozen"`) does NOT catch a reset-every-sweep regression (renders
`frozen 0s` either way) — assert the persisted anchor is unchanged across two
sweeps; mutation-verify it (force `at=now` → test must fail). See
[[typos-gate-blocks-push]] and [[golem-gate-watch-host-leak]] (push env-leak flake
hit on this PR too — `config.sh` #376 test fatals under leaked GIT_DIR, --no-verify + CI is the gate).
