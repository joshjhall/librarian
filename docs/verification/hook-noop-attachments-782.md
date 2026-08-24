# No-op hook attachments — issue #782

Records the in-tree hook audit and the **corrected cost attribution** for
[#782](https://github.com/joshjhall/librarian/issues/782) ("no-op hooks inject
empty `hook_success` attachments re-read for the whole session").

This file exists for two reasons. The in-tree audit **contradicts the issue's
premise** and needs its evidence on the record rather than in a PR comment. And
the actual emitter is **outside this repo's tree**, so librarian cannot fix it —
the only useful thing this repo can produce is an accurate, actionable
identification for the operator.

Measured on `feature/issue-782` at `6c0920f`, 2026-08-24.

## AC status

| # | Acceptance criterion | Status |
| --- | --- | --- |
| 1 | Every hook in `plugins/**/hooks/` emits nothing on the no-op path | **PASS** — already true before this issue; now gated |
| 2 | `dev-core` guidance documents silence-by-default with measured rationale | **PASS** — `shell-scripting/SKILL.md` § Hook Output Contract |
| 3 | A hook that must emit `{}` carries a comment saying why | **PASS (vacuous)** — no shipped hook emits on a no-op path, so none needs the comment; the rule is documented for the case that arises |
| 4 | Before/after measured with `token-report.sh`, delta recorded | **DEFERRED** → [#793](https://github.com/joshjhall/librarian/issues/793) |
| 5 | `docs/verification/` records the out-of-tree finding for operator action | **PASS** — this file |

## AC#1 — the in-tree audit contradicts the premise

The issue proposes auditing this repo's hooks for a "no-op but emits" pattern.
**No shipped hook has it.** Each was executed against a realistic payload for its
registered event and its stdout measured in bytes:

```bash
# no-op payload for a PreToolUse:Bash allow
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash",
  "tool_input":{"command":"ls -la"},"cwd":"'"$PWD"'","session_id":"t1"}' > /tmp/p.json
bash plugins/workflow/hooks/bash-guard.sh < /tmp/p.json > /tmp/out.txt 2> /tmp/err.txt
echo "rc=$?  stdout=$(wc -c < /tmp/out.txt)  stderr=$(wc -c < /tmp/err.txt)"
```

### VERIFIED — live

| hook | event / condition | rc | stdout | stderr |
| --- | --- | --- | --- | --- |
| `bash-guard.sh` | `PreToolUse:Bash`, benign command (allow) | 0 | **0 bytes** | 0 bytes |
| `worktree-guard.sh` | `PreToolUse:Edit`, target inside the worktree (allow) | 0 | **0 bytes** | 0 bytes |
| `golem-notify.sh` | `Notification`, no `GOLEM_ID` | 0 | **0 bytes** | 0 bytes |
| `golem-notify.sh` | `Notification`, `GOLEM_ID=golem-782` set | 0 | **0 bytes** | 0 bytes |
| `worktree-guard.sh` | `PreToolUse:Edit`, target **escapes** the worktree (deny) | 0 | 889 bytes | — |

The last row is **correct and must stay** — that is a decision being conveyed.
`golem-notify.sh` stays silent even on its active path because it writes to the
status feed, not to stdout; `claude-host-event.sh` (below) is silent for the
analogous reason.

**No hook was modified by this issue.** Adding a no-op edit to claim AC#1 would
be theater. What this issue adds instead is `tests/lint-hook-silence.sh`, which
turns an incidental property into an enforced one: it **executes** every hook
registered in `plugins/**/hooks/hooks.json` against a no-op payload and requires
zero bytes on stdout.

Two properties of that gate are deliberate:

- **It drives off `hooks.json`, not a hardcoded list**, so a newly registered
  hook is covered automatically instead of silently exempt.
- **It asserts the deny path still emits.** A silence-only gate is satisfiable
  by a hook that emits nothing ever — including when it must deny — which trades
  a token cost for a correctness hole. Both directions were mutation-tested (see
  below).

### Mutation round — the gate can fail

A gate that cannot fail is not a gate. Mutations applied to the tree and
reverted after each:

| # | Mutation | Result |
| --- | --- | --- |
| 1 | `printf "{}"` appended at end of `bash-guard.sh` | **SURVIVED** — line is unreachable (script exits earlier); confirmed by direct run: still 0 bytes. Not a gate defect |
| 2 | `printf "{}"` at the **reachable** allow exit (`[ -z "$matched" ]`) | **CAUGHT** |
| 3 | `_emit_deny "$reason"` replaced with a silent `exit 0` | **CAUGHT** |
| 4 | `printf "\n"` (bare newline) at the reachable allow exit | **CAUGHT** — "Observed 1 byte(s)" |
| 5 | a hook registered with an unresolvable command shape | **CAUGHT** — "command shape is unrecognized" |
| 6 | live-feed pollution probe (size/line delta around a gate run) | **delta 0** after isolation; **+1 line / +110 bytes** before |
| 7 | `_emit_deny_reason` neutered at the jq-absent fallback | **SURVIVED** — unreachable with jq present (the jq branch emits and exits first). Not a gate defect |
| 8 | `_emit_deny_reason` neutered at the **function entry** | **CAUGHT** — `bash-guard.sh still emits on the DENY path ... FAIL` |
| 9 | sentinel regressed from `exit 77` to `exit 0` | **CAUGHT** — `an absent jq exits 77, not 0 ... FAIL` |

Mutations 7 and 8 are the same lesson as mutation 1, met a second time: the
obvious target was dead code. `bash-guard.sh` emits its deny envelope through
`jq` when `jq` is present and only falls back to a hand-rolled `printf`
otherwise, so neutering the fallback changes nothing on a host that has `jq`.
Distinguishing *unreachable* from *untested* is what separates a real coverage
gap from a mutation that could never have failed.

Mutation 1 is worth recording rather than discarding: the obvious mutation
target was dead code, and a round that stopped there would have "proved" the
gate worked while testing nothing.

Mutations 4 and 5 exist because the **adversarial pre-PR review found three real
defects in the first version of this gate**, all of which had passed the first
mutation round. They are recorded here rather than quietly fixed, because each
is a distinct way a green gate can be hollow:

1. **The deny assertion self-skipped in CI.** It ran only when the *ambient*
   checkout was already a linked worktree, and called `skip_test` otherwise.
   `actions/checkout` produces a plain clone where `git-dir == git-common-dir`,
   so the assertion skipped on **every CI run** — the one environment that gates
   merge — while passing locally in the golem worktree where mutation 3 was
   measured. The evidence looked complete and covered nothing where it counted.
   Fixed by **building** a throwaway superproject + linked worktree inside the
   sandbox, so the check runs identically in any topology. Verified by running
   the gate inside a real plain clone (`git-dir: .git`, `common-dir: .git`):
   6/6 pass, **0 skipped**.
2. **An unresolvable command shape vanished from the corpus.** A registration
   whose command lacks the `${CLAUDE_PLUGIN_ROOT}` literal resolved to an empty
   script path and was silently dropped, while `test_corpus_non_empty` stayed
   green on its siblings — exactly the "silently exempt" outcome this gate
   claims to prevent. Now a loud failure naming the command.
3. **`assert_output_empty` was fed newline-stripped output.** Command
   substitution strips trailing newlines, so a hook emitting a bare `\n` read as
   empty and passed against a contract that says *zero bytes*. Now measured with
   `wc -c` on a captured file.

**Cycle 2 found a fourth defect the stdout assertion could not see.** The gate
ran each hook from the repo, and `golem-notify.sh` resolves its status feed from
the **actual process cwd** (`git rev-parse --git-common-dir`) — it never reads
the payload's `cwd`. So running the gate appended a synthetic line to the LIVE
`.worktrees/.status/feed.jsonl` that `golem-status.sh` and gate-watch read to
decide golem state. Measured before the fix:

```text
bytes: 122575 -> 122685   (delta 110)
lines: 1110 -> 1111 (delta 1)
POLLUTION CONFIRMED — appended lines:
{"ts":"2026-08-24T17:31:23Z","golem":"golem-782","event":"idle","message":"Claude is waiting for your input"}
```

The line was attributed to `golem-782` — the very session running the gate. Every
stdout assertion passed throughout, so a test about hook output was silently
corrupting orchestration state that no assertion looked at. Fixed by running each
hook from a throwaway git repo inside the sandbox, with `GOLEM_*` pointed there
and `GOLEM_EVENT_SINKS` emptied (so an operator env wired to a real sink cannot
make this gate POST a synthetic event). Same probe after the fix: **delta 0**.

Fixing (2) surfaced a further bug in the fix itself: a leading **empty** field
cannot survive `read` with `IFS=<tab>`, because tab is IFS *whitespace* and a
leading run of it is stripped — every column shifted left and the row was
misreported as a different hook (`registers Bash -> PostToolUse`). Corrected
with an explicit `UNRESOLVED` sentinel that keeps the field count fixed.

**Cycle 3 raised no real blocking finding** — the review loop converged. Its one
`blocking` row was the AC#4 scope item already resolved by the operator, filed
by the reviewer itself "purely for traceability rather than as a blocker". Four
deferrables were taken anyway, two of them guarding the cycle-2 isolation fix:

- a swallowed `git init` failure would leave `hookcwd` without a `.git`, freeing
  `git rev-parse --git-common-dir` to walk back up to the real checkout and
  silently restoring the escape route the fix had just closed — now a loud
  failure rather than `|| true`;
- a failed `cd` exited the subshell before its redirections fired, so the
  captures still held the PREVIOUS hook's bytes and would be reported under this
  hook's name — captures are now truncated before the run and the `127` sentinel
  is surfaced as itself;
- `bash-guard.sh` had no deny-path assertion though it is the higher-stakes
  denier (destructive shell in read-only subagents, #448/#662) — added, and
  mutation-verified;
- the sentinel-77 contract was asserted only in a comment — now pinned by two
  tests in `tests/validate-lint-gates.sh`, beside the sibling gates that
  implement the same contract.

## The real emitter — NOT `claude-host-event.sh`

The issue's `## Proposed Solution` item 4 attributes the dominant cost to the
operator's `~/.claude/hooks/claude-host-event.sh`. **That attribution is wrong**,
and acting on it would cost the operator time for no saving.

`claude-host-event.sh` is registered on 8 events (`SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
`Notification`, `Stop`, `SessionEnd`), all unmatched — so it does fire on every
tool call. But it **emits nothing**: every code path ends in

```bash
curl -s -m 1 -X POST "$url" ... >/dev/null 2>&1 &
...
exit 0
```

Both stdout and stderr are routed to `/dev/null`. Verified: no `echo`/`printf`/
`jq -n` reaches stdout anywhere in its 286 lines.

**The actual source is the `hookify` plugin** — visible in the issue's own
sample payload, whose `command` field reads
`python3 "${CLAUDE_PLUGIN_ROOT}/hooks/pretooluse.py"`. That is
`hookify@claude-plugins-official`, enabled in this operator's settings. Both of
its tool hooks carry the same line:

```python
# hookify/hooks/pretooluse.py:50   (and posttooluse.py:47)
# Always output JSON (even if empty)
print(json.dumps(result), file=sys.stdout)
```

An empty rule set evaluates to `{}`, and `{}` is printed anyway. That is the
~281-char, zero-information attachment, 1,645 times in one session.

This matches the issue's own per-hook table, where `PreToolUse:Bash` (771 fires)
and `PostToolUse:Bash` (768) account for ~428k of the ~463k measured chars — the
exact two events `hookify` registers.

### Operator action (out of this repo's tree)

`hookify` is a third-party plugin under
`~/.claude/plugins/marketplaces/claude-plugins-official/`. Librarian ships no
part of it and cannot patch it. Either fix works:

1. **Disable it** if its rules are unused — remove
   `"hookify@claude-plugins-official": true` from `enabledPlugins` in
   `~/.claude/settings.json`. This is the whole saving with no behavior change
   when no rules are configured.
2. **Patch the two hooks** to print only when there is something to say:

   ```python
   if result:                      # was: always print, "even if empty"
       print(json.dumps(result), file=sys.stdout)
   ```

   Keeps rule evaluation working; removes the empty-payload attachments.

Option 1 is the one to take if `hookify` has no configured rules — check with
`/hookify:list`.

Both the operator fix and the measurement that depends on it are tracked in
[#793](https://github.com/joshjhall/librarian/issues/793), so #782 does not stay
open on work that lives outside this tree.

## AC#4 — DEFERRED (recipe) → #793

`token-report.sh` **is** available (#781 merged as `6c0920f`), so the original
blocker is gone. AC#4 is still deferred for two reasons, the second more
important than the first:

1. `BIFROST_URL` is unset in this environment and absent from `.env`, and
   `token-report.sh` requires it with no default (deliberately — see its header:
   `ANTHROPIC_BASE_URL` is the *proxy* path and answers `/api/logs/stats` with
   HTML + HTTP 200).
2. **A #782 before/after would measure ~0 by construction.** No in-tree hook
   changed behavior in this PR — all three were already silent — so there is no
   in-tree delta to attribute. Running the harness against this change would
   produce a number that means nothing.

The measurable delta belongs to the **operator fix above**, not to this PR. Run
this once `hookify` is disabled or patched, on a comparable session:

```bash
export BIFROST_URL="http://<gateway-host>:<port>"

# Baseline: a window BEFORE the hookify change
plugins/workflow/scripts/token-report.sh window \
  --start 2026-08-23T00:00:00Z --end 2026-08-24T00:00:00Z --json \
  > /tmp/hookify-before.json

# After: an equivalent-length window AFTER it
plugins/workflow/scripts/token-report.sh window \
  --start <after-start> --end <after-end> --json \
  > /tmp/hookify-after.json

plugins/workflow/scripts/token-report.sh compare \
  --baseline /tmp/hookify-before.json \
  --compare  /tmp/hookify-after.json
```

Judge on **`avg_prompt_per_request`** (`prompt_tokens / requests`), not cost —
per that tool's header, cost moves with how hard the fleet is pushed, while the
average isolates an efficiency change from a workload change.

Expect the effect to be **real but modest against session noise**: 574,677
context tokens over 24h is the accumulated attachment weight, spread across many
sessions of differing length. Compare windows of similar shape, and treat a
single pair as indicative rather than conclusive.
