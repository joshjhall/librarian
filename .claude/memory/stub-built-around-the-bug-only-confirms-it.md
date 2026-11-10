---
name: stub-built-around-the-bug-only-confirms-it
description: "A recording stub that models the CURRENT invocation can only confirm it — agnix `validate --config` was rejected by the real binary for months while its stub-backed test stayed green"
type: feedback
metadata:
  node_type: memory
  originSessionId: 148628b2-70e3-48fa-af65-b354e70a89e4
  modified: 2026-11-09T18:59:13.197Z
---

A test stub written by reading the implementation inherits the implementation's
assumptions. If it parses arguments in the order the code emits them, it is
structurally unable to observe the order the **real** tool requires — so it
passes on the bug and would fail on the fix.

Measured on #471/#472 (PR #547): both agnix normalizers emitted
`agnix validate --config X`, but `--config` is a **global** flag that must
precede the subcommand; the real binary exits 2 with
`unexpected argument '--config' found`. The operator-config branch, the trust
posture's primary safe path, had never worked since #398. The test
`test_agnix_config_placement` stayed green because its recording stub only
started looking for `--config` **after** it saw `validate` — it was built
around the buggy order. The failure was also masked at runtime: both impls
sent agnix's stderr to `/dev/null`, so it surfaced only as the generic "no JSON
output" fail-loud.

**Why:** a stub replaces the one component whose behavior is in question. When
its contract comes from the caller rather than from the real tool, the test
measures self-consistency, not correctness — the same blind spot as a parity
gate over two impls that share a defect ([[parity-gate-hides-shared-defect]]).

**How to apply:** derive a stub's contract from the real tool — run it once
and record what it accepts and rejects (exit code + stderr), and make the stub
**reject** what the real tool rejects. Where the real binary is cheap to run,
add one case against it. Before trusting a stub-backed green, write the
*correct* invocation into the code and check the stub fails it — if it passes
both orders, it asserts nothing about order.
