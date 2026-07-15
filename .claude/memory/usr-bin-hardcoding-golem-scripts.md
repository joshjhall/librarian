---
name: usr-bin-hardcoding-golem-scripts
description: Golem/worktree scripts hardcode /usr/bin/<tool>;
metadata: 
  node_type: memory
  type: project
  originSessionId: 7d4c4ad1-c08c-4cae-86c2-13d22dff2b5e
---

The workflow plugin's golem/worktree scripts invoke coreutils/git by hardcoded
absolute path (`/usr/bin/{mkdir,cp,dirname,git,grep,...}`), which dies with exit
127 on hosts where the tools aren't at `/usr/bin` (Nix/Homebrew, external-volume
checkouts, non-standard macOS). The portable fix is the **`command <tool>`**
builtin — it's PATH-resolved but still alias/function-proof, preserving the
anti-shadowing intent documented in `config.sh:42-43`.

**Why:** #228 (PR #241) fixed **only** `plugins/workflow/scripts/worktree-new.sh`
(the issue was scoped to it). The identical pattern still lives in
`worktree-rm.sh`, `golem-notify.sh` (hooks/), `golem-watch.sh`, and
`config.sh:repo_root()`.

**How to apply:** worth a separate sweep issue to make the whole golem script
family PATH-portable — swap every `/usr/bin/<tool>` → `command <tool>`, leave the
`#!/usr/bin/env bash` shebang alone. The `tests/validate-golem-scripts.sh`
static-guard test added in #228 is the template for a regression gate.
