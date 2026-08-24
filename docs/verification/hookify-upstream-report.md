# Upstream report — hookify empty-payload emission

Ready-to-file issue body for
[`anthropics/claude-plugins-official`](https://github.com/anthropics/claude-plugins-official).
Written during the [#782](https://github.com/joshjhall/librarian/issues/782)
golem run; see `hook-noop-attachments-e2e-782.md` for the full audit.

**Not yet filed.** The token available in that session is fine-grained and scoped
to this account's own repositories, so `gh issue create` against `anthropics/*`
returns `Resource not accessible by personal access token`. Filing is tracked as
an acceptance criterion on
[#793](https://github.com/joshjhall/librarian/issues/793). Copy the body below
verbatim; suggested title:

> hookify: all four hooks print `{}` when no rule matches, adding a
> zero-information record to every fire

---

## Summary

All four `hookify` hooks unconditionally print their result to stdout, even when
that result is the empty dict `{}`. With no rules configured — or with rules that
simply don't match — every hook fire emits a ~2-byte JSON payload that carries no
decision and no message.

Because each fire becomes a hook record in the session transcript that is re-read
on subsequent turns, a plugin that is doing nothing still accrues context cost for
the whole session.

## The code

The same three lines appear in all four hooks:

```python
# hooks/pretooluse.py:50, posttooluse.py:47, stop.py:39, userpromptsubmit.py:39
# Always output JSON (even if empty)
print(json.dumps(result), file=sys.stdout)
```

`RuleEngine.evaluate_rules()` documents its own empty case —
*"Empty dict `{}` if no rules match"* (`core/rule_engine.py:47`) — and that value
is printed anyway. The comment "even if empty" names precisely the case that
should print nothing.

## Reproduction

With no `hookify.*.local.md` rule files present:

```bash
H=~/.claude/plugins/cache/claude-plugins-official/hookify/unknown
cd "$H" && export CLAUDE_PLUGIN_ROOT="$H"

printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp","session_id":"t1"}' \
  | python3 hooks/pretooluse.py
```

Observed, on `0fc2bb13a805`:

| hook | event | rc | stdout |
| --- | --- | --- | --- |
| `pretooluse.py` | `PreToolUse:Bash` | 0 | `{}` (2 bytes) |
| `posttooluse.py` | `PostToolUse:Bash` | 0 | `{}` (2 bytes) |
| `stop.py` | `Stop` | 0 | `{}` (2 bytes) |
| `userpromptsubmit.py` | `UserPromptSubmit` | 0 | `{}` (2 bytes) |

Expected: **zero bytes** on all four, since none has a decision to report.

## Why `{}` is not required here

The hooks reference states that exit code 0 with no output means the hook has no
decision to report and the tool call continues through the normal permission
flow, and advises that if you have nothing to say, plain `exit 0` with no output
is preferred — emitting `{}` gains nothing and only exposes you to the JSON
validation path.

So silence is the documented "proceed" signal. `{}` is strictly worse than
silence here: same outcome, plus a parse/validate pass, plus the record.

## Measured impact

From a 24h measurement on one machine, `hook_success` records were the largest
single attachment category — **574,677 context tokens**, with a **132.5M**
re-read total once each record's size is multiplied by the turns remaining in its
session. One session fired **1,645** of them. Per-event, the two highest were
`PreToolUse:Bash` (771 fires) and `PostToolUse:Bash` (768) — the events these
hooks register.

Those totals are for one operator's mixed hook set, so treat them as
order-of-magnitude rather than attributable to `hookify` alone. The direction is
what matters: the payloads in question contained no information at all.

## Suggested fix

Guard each of the four `print` calls on a non-empty result:

```python
if result:                      # nothing to say -> say nothing
    print(json.dumps(result), file=sys.stdout)
```

`result` is falsy exactly in the documented no-match case, so this is behavior
preserving for every rule that does match — blocks, warnings, and
`hookSpecificOutput` all still emit unchanged. The error paths
(`print(json.dumps(error_output))`) should keep printing; those carry a real
message.

Happy to open a PR with this change plus a test asserting zero bytes on the
no-match path for each of the four hooks, if that's welcome.

## Environment

- `hookify@claude-plugins-official`, commit `0fc2bb13a805`
- Reproduced with no rule files present; the same path is taken whenever loaded
  rules simply don't match the event.
