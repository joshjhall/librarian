---
name: die-inside-command-substitution-is-swallowed
description: "A fail-loud `die` inside `$(...)` only kills the subshell — the caller computes a verdict anyway (#596)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: e27f9ded-9f74-48fe-ba56-da0a45c3cf33
  modified: 2026-07-31T23:52:59.375Z
---

A helper that fails loud via `die`/`exit 2` **does not fail loud when called
inside `$(...)`** — the exit kills only the subshell. The parent prints the
message and carries on, producing exactly the confident-wrong-answer the die
existed to prevent.

Hit three times in #596 in one script:

```bash
fingerprints "$(read_findings "$prev")"        # die swallowed
done <<EOF
$(opt_all --prev-result -- "$@")               # die swallowed; here-doc discards status
EOF
```

**Remedies, in order of preference:**

1. Capture once and check the substitution's status:
   `val="$(helper "$x")" || die "..."` — assignment from `$(...)` propagates the
   command's exit code.
2. Materialize a repeatable list in the parent shell BEFORE the loop
   (`list="$(opt_all ...)" || exit 2`), then feed the variable to the here-doc.

**Do NOT** pre-check then re-read (`[ -r "$f" ] || die; use "$(read "$f")"`): that
validates a different read than the one used (TOCTOU) and duplicates the reader's
own checks so the two drift apart. One read, one status.

**Detection:** the symptom is an exit code of 0 alongside a printed error message.
Test exit codes directly (`cmd >/dev/null 2>&1; echo $?`), never via `| head`,
which reports the pipe's status. Related: [[grep-c-zero-count-exit-1]],
[[set-e-abort-untestable-in-run-test]].
