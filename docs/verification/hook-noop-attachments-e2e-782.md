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
| 4 | Before/after measured with `token-report.sh`, delta recorded | **PARTIAL** — two pre-fix baselines captured and reconciled; the after-window cannot exist until the fix has been live, so the delta closes on [#793](https://github.com/joshjhall/librarian/issues/793) |
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
| 10 | `hook_script_path` returns a bogus path instead of empty | **CAUGHT** |
| 11 | `write_noop_payload` accepts any event shape | **CAUGHT** |

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

**Cycle 4 returned `blocking: []` — the loop converged** after two consecutive
cycles with no real blocker. Two of its deferrables were taken:

- the gate's own **fallback branches were dead code** in every real run. The
  `UNRESOLVED` path and `write_noop_payload`'s catch-all exist to make an
  unmodellable registration fail loudly, but the live corpus matches every case,
  so neither executed in CI — a regression in either would silently restore the
  exemption this gate exists to prevent. Both are now exercised directly
  (mutations 10 and 11), independent of what is registered.
- this file was **renamed** to `hook-noop-attachments-e2e-782.md`. CLAUDE.md
  documents exactly two shapes for `docs/verification/` — `<skill>-e2e-<issue>.md`
  and `<topic>-tally-<issue>.md` — and the original name matched neither.
  [#793](https://github.com/joshjhall/librarian/issues/793) was updated to cite
  the new path.

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
and `PostToolUse:Bash` (768) account for ~428k of the ~463k measured chars — two
of the four events `hookify` registers.

A later probe (below) widened this: `hookify` registers **four** events, and all
four emit. The issue's table lists only the two tool events because those
dominate by fire count, but `Stop` and `UserPromptSubmit` emit the same `{}`.

### Operator action — APPLIED 2026-08-24

`hookify` is third-party, under `~/.claude/plugins/`. Librarian ships no part of
it and cannot patch it durably. The audit widened during this run, and two
findings changed the recommendation.

**All four hooks emit, not two.** #782's table only covered the `PreToolUse` /
`PostToolUse` pair. Executed against a no-match payload for each registered
event, with no rule files present:

#### VERIFIED — live

| hook | event | rc | stdout |
| --- | --- | --- | --- |
| `pretooluse.py` | `PreToolUse:Bash` | 0 | `{}` (2 bytes) |
| `posttooluse.py` | `PostToolUse:Bash` | 0 | `{}` (2 bytes) |
| `stop.py` | `Stop` | 0 | `{}` (2 bytes) |
| `userpromptsubmit.py` | `UserPromptSubmit` | 0 | `{}` (2 bytes) |

`RuleEngine.evaluate_rules()` documents its own empty case — *"Empty dict `{}` if
no rules match"* — and all four hooks print it anyway.

**A patch cannot be made durable.** Every lever was checked:

| Lever | Verdict |
| --- | --- |
| Patch the hook files | **Clobbered by `plugin update`.** Also **three** md5-identical copies exist (`cache/unknown`, `cache/<sha>`, and the `marketplaces/` checkout) — easy to patch the one that is not executing |
| Per-plugin hook toggle | **Does not exist.** Enable/disable is whole-plugin only; `skillOverrides` covers skills, with no `hookOverrides` counterpart |
| `disableAllHooks` | **Global.** Would also kill `worktree-guard.sh` and `bash-guard.sh` — trades a token cost for a correctness hole |
| `allowedHttpHookUrls` | **N/A** — applies to HTTP-type hooks; these are `command` type |

So disabling is the only durable fix, and `enabledPlugins` survives updates.

**What made it free here:** no `hookify.*.local.md` rule file exists anywhere on
this machine or in any project tree. With an empty rule set the plugin's entire
runtime contribution *is* the `{}` — the loader finds nothing and the engine
returns empty on every fire. Disabling costs no working behavior today; it gives
up the `/hookify:*` commands and the `conversation-analyzer` agent, and
re-enabling is a one-line revert whenever a rule is actually wanted.

Applied to `~/.claude/settings.json` (the file is outside this repo; recorded
here because nothing in-tree can show it):

```diff
-    "hookify@claude-plugins-official": true,
+    "hookify@claude-plugins-official": false,
```

Verified: JSON still parses, and the other 14 enabled plugins are untouched.

### Upstream

The one-line fix benefits every user of the plugin, so it belongs upstream at
`anthropics/claude-plugins-official` rather than only in one operator's settings:

```python
if result:                      # nothing to say -> say nothing
    print(json.dumps(result), file=sys.stdout)
```

`result` is falsy exactly in the documented no-match case, so this is behavior
preserving for every rule that *does* match; the error paths keep printing,
since those carry a real message.

A ready-to-file report is committed at `docs/verification/hookify-upstream-report.md`.
It was **not** filed from this session: the available token is fine-grained and
scoped to this account's own repos, so `gh issue create` against `anthropics/*`
returns `Resource not accessible by personal access token`. Filing it by hand is
tracked as an AC on #793.

## AC#4 — baseline captured, delta deferred to #793

`token-report.sh` is available (#781, `6c0920f`) and a gateway **is** reachable
from this environment, so the original blocker is gone. Two **pre-fix** windows
were captured on 2026-08-24, before the operator fix below was applied.

Endpoint deliberately omitted. The gateway is network-local to one operator and
most users of this repo run no gateway at all, so no host, port, or hostname
appears here or anywhere in the tree — `token-report.sh` requires `BIFROST_URL`
with **no default and no fallback**, which is the correct shape. Only the
resulting numbers are recorded.

### VERIFIED — live (pre-fix baselines)

```bash
export BIFROST_URL="https://<gateway-host>"   # network-local; never hardcoded

plugins/workflow/scripts/token-report.sh window \
  --start 2026-08-23T00:00:00Z --end 2026-08-24T00:00:00Z --json \
  > /tmp/hookify-before.json
```

| window | requests | avg prompt tokens / request | reconciliation |
| --- | --- | --- | --- |
| 2026-08-23 00:00–24:00Z (full day) | 17,906 | **144,372** | delta 2, tolerance 90 ✅ |
| 2026-08-24 00:00–19:00Z (partial) | 3,297 | **142,052** | delta 0, tolerance 16 ✅ |

Both reconciled against the unfiltered total. The two windows agree to **1.6%**
on `avg_prompt_per_request` despite differing in length and request count by
more than 5x — useful, because it establishes the **noise floor** against which
any post-fix delta must be judged. A change smaller than roughly 2% is not
distinguishable from ordinary day-to-day variation on this fleet.

### Why the delta is still deferred

The after-window cannot exist yet: the operator fix was applied at the end of
this session, so no post-fix period of comparable shape has elapsed. Capturing
it now would compare a full day against minutes.

**#793 owns the close-out**, using the baselines above rather than re-deriving
them. Re-run the same command over a post-fix window of similar shape and:

```bash
plugins/workflow/scripts/token-report.sh compare \
  --baseline /tmp/hookify-before.json \
  --compare  /tmp/hookify-after.json
```

Judge on **`avg_prompt_per_request`**, not cost — per that tool's header, cost
moves with how hard the fleet is pushed, while the average isolates an
efficiency change from a workload change.

### Predicted effect — and a caveat worth recording

Expect **real but modest** movement, and treat a single pair as indicative.

One tension belongs on the record rather than smoothed over. The hooks reference
says a hook that exits 0 **with no output** has nothing recorded on
`PreToolUse`/`PostToolUse` — implying silence costs *zero* context, not merely a
smaller record. That does not obviously square with #782's measurement, where
`hook_success` was the single largest attachment category at 574,677 context
tokens. Either the accounting attributes to `hook_success` something the docs
describe differently, or the emitting hooks (which printed `{}`, not nothing)
are the entire category.

The second reading is consistent with both facts and is the working hypothesis:
**it is the `{}` that creates the record; silence would have created none.** The
measurement on #793 is what discriminates — a near-zero delta would favor the first
reading and is a real possible outcome, so it should be reported as found rather
than fitted to this expectation.
