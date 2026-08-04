---
name: local-declaration-cannot-self-reference
description: "Under set -u, `local a=$1 b=$FIXTURE/$a` aborts with 'a: unbound variable' — one local statement's assignments all evaluate before any name is bound; split into separate local statements"
metadata:
  type: feedback
---

A single `local` statement cannot reference a variable it is itself declaring.
Under `set -u` this is not a subtle bug — it **aborts the function**:

```bash
# BROKEN — aborts: "a: unbound variable"
f() { local a="$1" b="/tmp/x-$a.sh"; ... }

# CORRECT
f() { local a="$1"; local b="/tmp/x-$a.sh"; ... }
```

**Why:** bash evaluates every assignment in the statement *before* binding any of
the names, so `$a` on the right-hand side reads the (unset) outer scope, not the
`a` being declared one word to its left. It reads like sequential assignment and
is not.

**How to apply:** when a helper's second `local` is derived from its first —
overwhelmingly the `local name="$1"` + `local out="$DIR/$name"` shape — give each
its own statement. Every test suite here runs `set -euo pipefail`, so the failure
is an immediate abort mid-suite, and the error names the variable being *read*
(`a`), not the statement that is malformed — which sends you looking at the
caller rather than the declaration.

**shellcheck catches it — so run the gate before the suite.** It is `SC2318`
("This assignment is used again in this 'local', but won't have taken effect. Use
two 'local's"), and it fires at `--severity=warning`, which is exactly what
`tests/lint-shellcheck.sh` runs. The lesson is therefore less "memorize the rule"
than **lint before you debug**: `bash tests/lint-shellcheck.sh` would have named
the line and the fix instantly, where the runtime abort points at the variable
being *read* rather than the malformed declaration and sends you looking at the
caller.

Related: [[set-e-abort-untestable-in-run-test]] — the other way `set -e`/`set -u`
semantics make a test function fail somewhere other than where it looks.
