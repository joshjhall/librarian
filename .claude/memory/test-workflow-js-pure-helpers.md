---
name: test-workflow-js-pure-helpers
description: "How to unit-test pure helpers inside a workflow.js harness that can't be imported"
metadata:
  node_type: memory
  type: reference
  originSessionId: 03199c36-6328-468a-ab08-f45a33c13dce
---

A `workflow.js` harness ends in a top-level `await agent()` / `return` at module
scope, so it CANNOT be `import`-ed (importing executes the orchestration; a
top-level `return` is also a syntax error outside a function). To unit-test its
pure helpers (`sanitize`, `dataBlock`, `stampRefs`, `finalResult`, `safeRef`,
`field`, `setsIntersect`, `defaultVerdict`, `refOf`, `emptyReport`/`emptyResult`):

read the source, slice everything BEFORE the first column-0 orchestration
statement (regex on `^(log\(|phase\(|await |const x = await|if \(|for \(|return )`
with the `m` flag), strip `export` off `export const meta`, then eval the pure
prefix in `new Function('args','budget','log','phase','agent','parallel','pipeline', prefix + 'return {…}')`
with inert stubs. Seed `args` to satisfy config consts the prefix derives at load
(e.g. next-issue-ship's `emptyResult` reads CYCLE/PHASE/scopeFiles from args).

Cutting before the first top-level `await` is mandatory — a `new Function` body
containing top-level await throws at construction; assert that failure mode as a
negative self-check so a boundary-regex regression can't make the gate silently
pass. The `new Function` is NOT an injection surface here: only the repo's own
committed source + a hardcoded identifier allowlist are interpolated (the
PostToolUse security hook warns generically; this case is safe).

Implemented as `tests/validate-workflow-helpers.mjs` (zero-dep, node-only, gated
like `validate-manifests.mjs` in run-all.sh) for issue #78 / PR #121. Relates to
[[two-runtime-model]] and [[workflow-js-no-module-system]].
