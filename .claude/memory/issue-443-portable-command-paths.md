---
name: issue-443-portable-command-paths
description: "#443 repo-wide sweep of hardcoded /usr/bin//bin tool paths to `command <tool>` + _bin() resolver for stripped-PATH scripts + CI lint; the big gotcha = several classes MUST NOT be swept"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2e00fe92-7847-4f32-8736-90367f40c1a5
  modified: 2026-07-24T04:59:42.457Z
---

**#443** SHIPPED PR (feature/issue-443, L3, awaiting merge) — replaced ~1,500
hardcoded `/usr/bin/<tool>` + `/bin/<tool>` invocations across plugins/ tests/
bin/ with the `command <tool>` builtin (portable: honors PATH, works on macOS
where core utils are in /bin, Homebrew git elsewhere). Extends #241 (which fixed
only worktree-new.sh; see [[usr-bin-hardcoding-golem-scripts]]). Adds a CI lint
in tests/lint-shell-portability.sh banning new hardcoded tool paths.

**THE BIG LESSON: a "convert every /usr/bin/X" sweep has FIVE must-NOT-touch
classes a blind regex will corrupt — each cost a test-failure debug cycle:**

1. **Shebangs** `#!/usr/bin/env bash` (line 1) + `/usr/bin/env` anywhere — env is
   the one tool with a stable path; env EXECS its arg as a real binary, so
   `env ... command <tool>` is BROKEN (`command` is a builtin). Revert to bare
   `<tool>` (env resolves via PATH).
2. **Stripped-PATH scripts** — 3 PreToolUse hooks (bash/worktree/golem-notify)
   + 5 scripts with no-jq/liveness paths tested under a hermetic PATH
   (golem-status/gate-watch/inbox/resolve/transcript-liveness). `command <tool>`
   CAN'T resolve an external core utility when PATH is stripped. FIX = a `_bin()`
   resolver: `command -v` first, then scan bare DIRS
   (/usr/bin /bin /usr/local/bin /opt/homebrew/bin /sbin /usr/sbin), then bare
   name; resolve each tool ONCE into an UPPERCASE var; define BEFORE SCRIPT_DIR
   (so `command dirname` there is also portable). Bare dirs (not /usr/bin/X
   literals) keep the lint from flagging the resolver itself.
3. **Match-DATA** — bash-guard.sh deny-set `case` patterns
   (`rm | /bin/rm | /usr/bin/rm`) are the absolute-path forms the guard DETECTS
   in a scanned command, NOT invocations. Keep literal; mark `# lint-allow-path:`.
4. **Generated-stub internals** — a test stub NAMED `mktemp` on the stub PATH
   whose body delegates to the real tool MUST use an absolute/captured-real path,
   else `command mktemp` inside it RECURSES into the stub. Capture
   `real=$(command -v mktemp)` before the stub shadows PATH, interpolate it.
5. **Shebang/path DATA in strings** — `printf '#!/bin/sh\n'` writing a fixture
   script's shebang, and project paths like `$ROOT/bin/lib/x.sh` (a `/bin/lib`
   that a greedy regex reads as tool `lib`).

**Lint regex gotchas** (PATHLIT_RE): needs BOTH a leading boundary (skip
/usr/local/bin, already-command'd) AND a trailing `[^/A-Za-z0-9_.-]` boundary
(skip deeper project paths `$ROOT/bin/lib/...`, `$sb/bin/x.sh`). Exempt `env`
PROCEDURALLY (blank it before scan), NOT via an in-regex `[a-df-z]` first-letter
class — that silently skips ALL e* tools (echo/expr/eval), a false-negative the
adversarial review caught. Provide a `# lint-allow-path: <reason>` marker escape
hatch for classes 3+4.

Review also caught: a mechanical sweep collapsed a real two-arm fallback
(`/usr/bin/sleep || command sleep`) into a dead duplicate — check `"$V" || "$V"`
shapes after any var-substitution sweep.

Live-verified the L3 /golem path (routine gates auto-pass, plan gate kept, chains
ship in-turn, parks at self-merge). Teardown: /golem --teardown 443 after merge.
