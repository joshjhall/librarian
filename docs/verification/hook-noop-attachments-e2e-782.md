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
| 1 | Every hook in `plugins/**/hooks/` emits nothing on the no-op path | **PASS** — already true before this issue; now gated. (The *operator-side* `hookify` fix is host-only and is re-enabled in every container — see § AC#1 revisited) |
| 2 | `dev-core` guidance documents silence-by-default with measured rationale | **PASS** — `shell-scripting/SKILL.md` § Hook Output Contract |
| 3 | A hook that must emit `{}` carries a comment saying why | **PASS (vacuous)** — no shipped hook emits on a no-op path, so none needs the comment; the rule is documented for the case that arises |
| 4 | Before/after measured with `token-report.sh`, delta recorded | **MEASURED, NOT CONCLUSIVE (#793, 2026-09-03)** — 9-day post-fix window; `avg_prompt_per_request` rose **+13.5%**, i.e. **no saving is detectable**. Reported as found. A contamination confound (containers#897) remains until that lands; see § AC#4 |
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
| `pretooluse.py` | `PreToolUse:Bash` | 0 | `{}` + newline (3 bytes) |
| `posttooluse.py` | `PostToolUse:Bash` | 0 | `{}` + newline (3 bytes) |
| `stop.py` | `Stop` | 0 | `{}` + newline (3 bytes) |
| `userpromptsubmit.py` | `UserPromptSubmit` | 0 | `{}` + newline (3 bytes) |

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

A ready-to-file report is at the end of this file (§ Upstream report). It was
**not** filed from this session: the available token is fine-grained and scoped
to this account's own repos, so `gh issue create` against `anthropics/*` returns
`Resource not accessible by personal access token`. Filing it by hand is tracked
as an AC on #793.

## AC#4 — baseline captured; delta MEASURED on #793 (no saving found)

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
on `avg_prompt_per_request` while differing **5.4x in request count** (17,906 vs
3,297) and **4.3x in throughput** (746 vs 174 requests/hour). Their *durations*
are close — 24h vs 19h, only 1.26x — so the independence here is in how hard the
fleet was pushed, not in how long each window ran.

That is what makes the pair useful: it establishes a **noise floor** against
which any post-fix delta must be judged. A change smaller than roughly 2% is not
distinguishable from ordinary variation on this fleet.

Treat that bound as **indicative, not statistical**. Two windows on consecutive
days sharing a start-of-day boundary are not independent samples, so 1.6% is the
observed spread of one pair rather than a confidence interval. It is a floor to
clear, not a threshold to test against.

### VERIFIED — live (post-fix window, measured 2026-09-03 on #793)

The after-window now exists. Same tool, same endpoint shape, baselines **reused
rather than re-derived** (the 2026-08-23 window was re-run as a control and
reproduced the recorded figures exactly, at the same reconciliation delta).

**Figures below are NORMALIZED**, per the precedent in
`token-baseline-tally-781.md` § *Why no absolute figures*: averages, ratios and
reconciliation deltas are committed; raw fleet request counts and dollar totals
are not, because this repo is public and a ratio is exactly as good a
before/after anchor. `token-report.sh` reprints the absolutes on demand for
anyone with `BIFROST_URL` and access.

```bash
# NOTE the recipe on #793 said --json for both files. That is WRONG:
# `compare` parses the TSV contract (it skips any line with NF < 7), so two
# --json files match zero rows and it prints a full table of `n/a` at exit 0.
# Capture WITHOUT --json for compare. See "A trap worth recording" below.
plugins/workflow/scripts/token-report.sh window \
  --start 2026-08-26T00:00:00Z --end 2026-09-04T00:00:00Z > /tmp/after.tsv

plugins/workflow/scripts/token-report.sh compare \
  --baseline /tmp/before.tsv --compare /tmp/after.tsv --percent-only
```

| window | span | volume (relative) | reconciliation |
| --- | --- | --- | --- |
| pre-fix baseline | 2026-08-23 (24h) | 1.00x (reference) | delta 2, tolerance 90 ✅ |
| post-fix | 2026-08-26 → 09-04 (9d) | ~5.0x the baseline window | delta 0, tolerance 449 ✅ |

`2026-08-24`/`08-25` are excluded as a transition boundary: the fix landed at
the end of 08-24, so neither day is cleanly pre- or post-fix.

#### Result — `avg_prompt_per_request` moved the WRONG WAY

```text
model                              requests  prompt_tokens         cost    avg/req
claude-opus-5                       +425.5%        +447.9%      +447.9%      +4.3%
claude-sonnet-5                     +383.1%        +513.0%      +483.2%     +26.9%
TOTAL                               +401.3%        +468.9%      +455.1%     +13.5%
```

**The average prompt per request rose 13.5%.** No saving is visible. Three
checks were run before accepting that, because a headline number moving the
wrong way is exactly when a measurement deserves suspicion:

1. **Is it model-mix shift?** Decomposed: holding the *pre* mix and applying
   post per-model averages still gives **+11.5%**; the pure mix effect is only
   **+2.2%** (opus share 41.8% → 43.9%). So the rise is **within-model**, not an
   artifact of routing more traffic to the expensive model.
2. **Is it inside day-to-day noise?** No — and the issue's **1.6% floor is far
   too tight**. That figure came from two windows sharing a start-of-day
   boundary. Measured per-day across 14 days, the daily `avg/req` spread is
   **38% (opus)** and **13% (sonnet)** pre-fix, widening after. Request-weighted
   pre→post: opus **+11.7%**, sonnet **+30.9%**. Sonnet's rise clears any
   plausible noise band; opus's does not clear its own 38% spread.
3. **Did the filter silently drop?** No — both windows reconciled (delta 2 and
   0), and the plural `?models=` spelling was verified to reproduce the recorded
   8/23 opus figures exactly (matching request count and average).

#### What this means

**The measurement does not support the predicted saving.** It does *not* follow
that the effect is too small to matter — and an earlier draft of this section
made exactly that error, sizing the effect from the hook's **3-byte emission**.
That is the wrong quantity. #782 measured the resulting transcript **record** at
~281 chars (~70 tokens); at 1,645 fires that accumulates to **~115k tokens by
end of session** — about **80%** of an average prompt at that point. Since the
attachments accrue roughly linearly through a session, the *time-averaged*
contribution is about half the end-of-session total, i.e. **~40%** of an average
prompt across the session. Either way this is a **large** predicted effect,
which makes its complete absence from the measurement the genuinely interesting
result — not a null too small to see.

This **favors the first reading** of the tension recorded above — that
`hook_success`'s 574,677-token figure attributes to that category something the
hooks reference describes differently — rather than the working hypothesis that
the `{}` *is* the whole category. It is reported as found, per the issue's own
instruction that a near-zero delta is a real possible outcome. Note the observed
delta is not merely near-zero but **positive**, which is stronger evidence
against the hypothesis than a null result would be.

**Two confounds keep this from being conclusive**, and both are on the record
rather than smoothed over:

- **The after-window is contaminated.** See the container finding below — every
  devcontainer re-enabled `hookify`, so a substantial share of post-fix traffic
  was still emitting. A contaminated after-window biases the delta *toward zero*;
  it cannot explain a delta that is **positive**, so it weakens the null reading
  without rescuing the hypothesis.
- **The workload is not shape-matched.** The post window ran ~5x the baseline
  window's request volume, spread over 9 days against a single day.
  `avg_prompt_per_request` was
  chosen precisely because it is workload-robust, and the pre-fix pair did hold
  to 1.6% across a 5.4x throughput difference — but this is a wider gap still.

A clean re-measurement is worth doing once containers#897 lands, precisely
because the predicted effect (~40% of an average prompt) is far **above** this
fleet's day-to-day variance and should therefore have been visible. Its absence
in a window where a large share of traffic still emitted is consistent with the
contamination — but it is equally consistent with the first reading above, that
the `hook_success` accounting does not mean what #782 took it to mean. The
re-measurement is what separates those two, and it is the only remaining way to
settle the question.

#### A trap worth recording

`compare` consumes the **TSV** contract, not `--json`. Its awk parser skips any
line with `NF < 7`, and a JSON file has none — so feeding it two `--json`
captures prints a complete, well-formed table of `n/a` and **exits 0**. It looks
like a tool that ran fine and found nothing to say. The recipe on #793 (and the
one in this file's original AC#4 block) specified `--json` for both files, so
this was hit on the first attempt. Same failure family as the `?model=` vs
`?models=` trap the tool was built to guard: a wrong answer that reads as a
right one.

## AC#1 revisited — the fix is NOT durable in containers

AC#1 is marked applied, and it is — **on the host**. The edit to
`~/.claude/settings.json` does not survive into containers built from the
pinned `containers` image:

`containers/lib/features/lib/claude/claude-setup:1045` lists `hookify` in
`DEFAULT_PLUGINS`, and #784 made every plugin on that list **unconditionally
re-enabled** on each boot. Measured inside this repo's own devcontainer
(`v4.19.27`, `e5d4f70d`), with no rule file present anywhere:

### VERIFIED — live (container, post-"fix")

| hook | event | rc | stdout |
| --- | --- | --- | --- |
| `pretooluse.py` | `PreToolUse:Bash` | 0 | `{}` + newline (**3 bytes**) |
| `posttooluse.py` | `PostToolUse:Bash` | 0 | `{}` + newline (**3 bytes**) |
| `stop.py` | `Stop` | 0 | `{}` + newline (**3 bytes**) |
| `userpromptsubmit.py` | `UserPromptSubmit` | 0 | `{}` + newline (**3 bytes**) |

`"hookify@claude-plugins-official": true` in the container's settings. Note the
byte count is **3, not the 2 recorded earlier** — `print()` appends a newline.
Small, but it is the number this file asserts, so it is corrected here and in
the upstream report below.

Filed as
[joshjhall/containers#897](https://github.com/joshjhall/containers/issues/897):
**drop `hookify` from `DEFAULT_PLUGINS`** so it is opt-in via `CLAUDE_PLUGINS`.
Deliberately *not* a `CLAUDE_DISABLED_PLUGINS` entry — `claude-setup:438`
documents that as an emergency kill-switch rather than a configuration knob,
`claude-setup:508` names removal from the list as the supported opt-out, and a
deny-list entry would fix only one repo while every other repo on the image kept
re-enabling it. The issue also records that `claude-setup` never disables an
already-enabled plugin (`:451`), so existing containers need a one-time
`claude plugin disable hookify`.

The pinned submodule was **not** edited from the #793 run — CLAUDE.md pins it
(`update = none`) for devcontainer builds only.

## #793 disposition — two ACs stay open

This file closes #793's **measurement** ACs; two remain genuinely open, so
issue #793 must **not** be auto-closed on the strength of this work:

| #793 AC | State |
| --- | --- |
| hookify disabled/patched on the operator machine | **PARTIAL** — host yes, containers no (§ AC#1 revisited); [containers#897](https://github.com/joshjhall/containers/issues/897) |
| Filed upstream against `claude-plugins-official` | **OPEN — blocked** on a token with issue-write there (§ below) |
| Before/after captured with `token-report.sh` | **DONE** (§ AC#4) |
| Delta recorded in this file | **DONE** (§ AC#4) |

The delivering commit therefore says **`Contributes to #793`**, not
`Closes #793` — a squash-merge would otherwise auto-close an issue with two
unmet criteria. #793 stays open pending the upstream filing and a clean
re-measure once containers#897 lands.

## Upstream report — ready to file

The one-line fix benefits every user of the plugin, so it belongs upstream at
[`anthropics/claude-plugins-official`](https://github.com/anthropics/claude-plugins-official)
rather than only in one operator's settings.

**Still not filed — retried 2026-09-03 on #793 and refused again.** The token now
*reads* `anthropics/claude-plugins-official` fine (`gh api repos/...` → 200,
`permissions: {pull: true, push: false}`), so the repo is reachable; but
`gh issue create` still returns
`GraphQL: Resource not accessible by personal access token (createIssue)`.
Read access is not write access — filing needs a token with issue-write scope
there, or filing by hand through the web UI. A duplicate search was run first
(15 open `hookify` issues plus four targeted phrase searches): **no existing
issue covers the empty-payload defect**, so this is still worth filing. Copy the
body below verbatim; suggested title:

> hookify: all four hooks print `{}` when no rule matches, adding a
> zero-information record to every fire

---

### Summary

All four `hookify` hooks unconditionally print their result to stdout, even when
that result is the empty dict `{}`. With no rules configured — or with rules that
simply don't match — every hook fire emits a 3-byte JSON payload (`{}` plus the
newline `print` adds) that carries no
decision and no message.

Because each fire becomes a hook record in the session transcript that is re-read
on subsequent turns, a plugin that is doing nothing still accrues context cost for
the whole session.

### The code

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

### Reproduction

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
| `pretooluse.py` | `PreToolUse:Bash` | 0 | `{}` + newline (3 bytes) |
| `posttooluse.py` | `PostToolUse:Bash` | 0 | `{}` + newline (3 bytes) |
| `stop.py` | `Stop` | 0 | `{}` + newline (3 bytes) |
| `userpromptsubmit.py` | `UserPromptSubmit` | 0 | `{}` + newline (3 bytes) |

Expected: **zero bytes** on all four, since none has a decision to report.

### Why `{}` is not required here

The hooks reference states that exit code 0 with no output means the hook has no
decision to report and the tool call continues through the normal permission
flow, and advises that if you have nothing to say, plain `exit 0` with no output
is preferred — emitting `{}` gains nothing and only exposes you to the JSON
validation path.

So silence is the documented "proceed" signal. `{}` is strictly worse than
silence here: same outcome, plus a parse/validate pass, plus the record.

### Measured impact

From a 24h measurement on one machine, `hook_success` records were the largest
single attachment category — **574,677 context tokens**, with a **132.5M**
re-read total once each record's size is multiplied by the turns remaining in its
session. One session fired **1,645** of them. Per-event, the two highest were
`PreToolUse:Bash` (771 fires) and `PostToolUse:Bash` (768) — the events these
hooks register.

Those totals are for one operator's mixed hook set, so treat them as
order-of-magnitude rather than attributable to `hookify` alone. The direction is
what matters: the payloads in question contained no information at all.

### Suggested fix

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

### Environment

- `hookify@claude-plugins-official`, commit `0fc2bb13a805`
- Reproduced with no rule files present; the same path is taken whenever loaded
  rules simply don't match the event.
