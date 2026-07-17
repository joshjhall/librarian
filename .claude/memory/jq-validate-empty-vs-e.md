---
name: jq-validate-empty-vs-e
description: "To test \"is this valid JSON\" use `jq empty`, not `jq -e .` — the latter keys exit on output truthiness"
metadata: 
  node_type: memory
  type: reference
  originSessionId: bae2b1da-28e8-4ef6-a0b4-2a6b292def61
---

For a **syntax-only "is this well-formed JSON" check**, use `printf '%s' "$v" | jq empty`
(reads input, emits nothing, exits non-zero only on a parse error).

Do **not** use `jq -e .` for validity: `-e` sets exit status from the *truthiness*
of the filter's output, so the perfectly valid JSON scalars `false` and `null`
exit non-zero and get misreported as invalid.

Surfaced by the ship-issue pre-PR adversarial review on #253/PR #351, where the new
`tests/lib/harness.sh` `assert_valid_json <value> [message]` helper first shipped
with `jq -e .` and was hardened to `jq empty` inline (deferrable → applied). That
helper is the untrusted-safe replacement for the eval-embedding `assert_true
"printf '%s' '$NOTIFY_LINE' | jq -e ."` pattern — it takes the value as a real
argument so an embedded single quote can't break out of an eval'd command
(mirrors `assert_not_contains`). Follow-up self-test coverage tracked in #352.
