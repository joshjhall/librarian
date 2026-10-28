---
name: agnix-reads-angle-bracket-placeholders-as-xml
description: "agnix (CI pin) flags some `<word>` placeholders in skill/CLAUDE.md prose as \"Unclosed XML Tag\" errors, even inside backticks — write a concrete example path instead of an angle-bracket placeholder"
type: reference
status: stable
stale_after: 2027-04-30
stale_check: "the agnix pin in .github/workflows/ci.yml (grep 'agnix@'); re-test whether `<script>` inside backticks in a plugins/**/*.md still errors at that version"
metadata:
  node_type: memory
  originSessionId: bbc72ba7-7a06-48df-83d0-9ff560db09c5
  modified: 2026-10-27T22:10:50.964Z
---

agnix's "Unclosed XML Tag" rule fires on `<word>` placeholders in prose it scans
(`CLAUDE.md`, `AGENTS.md`, `plugins/`), and backticks do **not** protect them.

Measured on #1247 (PR #1251), agnix 0.54.0: `` `bash <script>` `` and a span
`` `bash <gate> > log …` `` in `next-issue/worktree-safe-recipes.md` each raised
an error, reddening both the `agnix` check and the `30-scanners` shard. In the
same file and run, `` `<id>` ``, `` `<worktree>` `` and `` `<skill-base-dir>` ``
did **not** fire, and neither did `` `bash <script>` `` in `CLAUDE.md`. The rule
that separates them was not determined — `script` is an HTML element but `gate`
is not, so it is not a known-element list.

**Why it bites:** agnix is not installed in the devcontainer, so its gate SKIPs
locally and CI is the first place it runs — see
[[skip-inside-a-green-banner-is-not-a-pass]].

**How to apply:** in prose under those roots, prefer a concrete example over an
angle-bracket placeholder (`tests/x.sh`, `work-0-none`, `.worktrees/issue-N`).
That is what fixed #1251, and it also reads better. Placeholders already on main
have passed CI and need no churn. If agnix flags one, rewrite the span rather
than adding an `.agnix.toml` override — the gate's header forbids suppressing
findings that way.
