---
name: pre-review-gates-needs-filelist
description: pre-review-gates.sh requires a file-list arg; bare invocation errors with Usage
metadata:
  node_type: memory
  type: reference
  originSessionId: 38cd8f66-5b91-4af5-b41f-c131957b0c9f
---

`plugins/workflow/skills/ship-issue/pre-review-gates.sh` takes the changed
files as **positional args** — a bare `bash pre-review-gates.sh` exits with
`Usage: pre-review-gates.sh <file-list>`. Pass the diff explicitly, e.g.
`bash …/pre-review-gates.sh $(git diff --name-only HEAD~1..HEAD)`. Exit 0 +
no output = clean. Related: [[pre-review-gates-project-root]].
