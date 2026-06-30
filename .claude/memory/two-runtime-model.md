---
name: two-runtime-model
description: "Workflow.js runs in the Claude binary's sandboxed JS engine (no shell/fs); only Bash-tool subagents reach host tools — and Claude Code bundles no general-purpose runtime"
metadata:
  node_type: memory
  type: reference
  originSessionId: 9d03d497-52a7-4a29-8c82-1ca6971f87ee
---

Claude Code (v2.1.195 here) ships as ONE ~241 MB self-contained binary at
`~/.local/share/claude/versions/<v>`. It embeds a JS engine, but that engine is
exposed ONLY as the interpreter for Workflow-tool `workflow.js` scripts. It does
NOT bundle a general-purpose `bash`/`python`/`node`/`deno` for plugins to call.

Two distinct runtimes — don't conflate them:

1. **`workflow.js` engine** (inside the Claude binary): sandboxed. No filesystem,
   no `child_process`/shell, no Node APIs; `Date.now()`/`Math.random()` THROW (so
   resume stays deterministic). Only JS built-ins + the `agent()/parallel()/
   pipeline()/log()/phase()` hooks. This is the load-bearing reason a harness
   cannot run `patterns.sh`, walk the tree, or call git itself.
2. **Bash-tool subagents** (e.g. `checker`, `issue-writer`): full host PATH —
   bash, node, python3, jq, git, gh. Anything shell/fs/git happens HERE.

The `node v22 / python3 3.13 / bash 5.2 / jq` visible on PATH come from the
**host devcontainer**, NOT from Claude Code. A bare Mac/Linux host may have none
of them. So "lean on a bundled runtime" is not an option — there isn't one.

**Why it matters:**

- Harness design (e.g. [[release-process]]-style automation, the codebase-audit
  harness in #18): the harness is pure orchestration; ALL shell/fs/git work must
  live in a Bash-capable subagent driven in discriminated modes (the pattern
  `next-issue-ship/workflow.js` uses to drive `code-reviewer`).
- Issue #17 ("multi-language/multi-runtime support" for skill code tools): there
  is no Claude-bundled runtime to standardize on. The real axis is
  lowest-common-denominator POSIX `bash` (what `patterns.sh` already targets)
  PLUS graceful degradation when an optional richer runtime (`python3`, a given
  `node`) is absent — never hard-fail the scan. That reframes #17's title.
