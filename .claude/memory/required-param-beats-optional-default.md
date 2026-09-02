---
name: required-param-beats-optional-default
description: "Fixing a wrong default by keeping the param optional preserves the footgun; require it so omission fails loud, and test that"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9c400633-e99b-465d-ae23-722ebd1f208a
  modified: 2026-09-01T18:29:17.909Z
---

When a helper's parameter defaults to a value that is **wrong for some callers**,
make the parameter **required** — do not keep it optional with a smarter default.
An optional parameter leaves the silent-wrong-default available to the next
caller who omits it: the defect preserved as a footgun.

**Why:** under `set -u` a required parameter turns omission into a loud abort at
the call site, converting a silent wrong value into an immediate error. It is the
repo's fail-loud policy applied to an API shape rather than to a tool's exit code.

**How to apply:**

- Re-signature, then update **every** call site explicitly (`grep -n -A1` the call
  to see which variant each site needs — sites can differ, e.g. one helper taking
  a bare basename while its twin takes a full path).
- Write a test that pins *what "required" buys*: call it with the argument
  omitted, in a **subshell** so the `set -u` abort fails one case instead of
  killing the suite, and assert non-zero. Without it the property lives only in a
  comment and a future `x="${2:-default}"` reinstates the defect with every other
  test green — verified by exactly that mutation (#767).
- Also guard the **wrong-value** path, not just the omitted one: if the resolver
  swallows its own errors, a typo'd argument still yields empty. Assert the
  diagnostic text too — "fail loud" is two claims (non-zero **and** a message
  naming the offender), and a test that discards stderr pins only half of it.
- Guard the **caller**, not the shared helper, when the helper's swallowing is
  pre-existing and other callers depend on it; hardening it is scope drift.

See [[comment-asserts-intent-not-code]], [[fixture-must-express-the-divergent-case]],
[[harden-one-knob-grep-every-sibling]].
